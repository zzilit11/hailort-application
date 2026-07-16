/**
 * Two-process direct-mode inference worker.
 *
 * Each OS process creates its own HailoRT objects and opens the device directly.
 * The HailoRT multi-process service is deliberately disabled.  The optional file
 * barrier lets a launcher start inference in two independently configured
 * processes at nearly the same time.
 */

#include "hailo/hailort.hpp"
#include "util.hpp"

#include <opencv2/opencv.hpp>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <limits>
#include <mutex>
#include <numeric>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

namespace fs = std::filesystem;
using namespace hailort;

namespace {

constexpr hailo_format_type_t FORMAT_TYPE = HAILO_FORMAT_TYPE_AUTO;
constexpr uint32_t DEVICE_COUNT = 1;
constexpr size_t DEFAULT_RESULT_TOP_K = 3;
constexpr size_t DEFAULT_RESULT_LOG_EVERY = 10;
constexpr auto BARRIER_TIMEOUT = std::chrono::seconds(120);
constexpr auto BARRIER_POLL_INTERVAL = std::chrono::milliseconds(10);

std::string g_worker_id = "standalone";
std::mutex g_log_mutex;

struct Options {
    std::string hef_path;
    std::string image_path;
    std::string labels_path;
    size_t frame_count;
    uint16_t batch_size;
    uint8_t priority;
    uint32_t timeout_ms;
    uint32_t threshold;
    size_t result_top_k = DEFAULT_RESULT_TOP_K;
    size_t result_log_every = DEFAULT_RESULT_LOG_EVERY;
    bool use_barrier = false;
    fs::path barrier_dir;
};

struct ThreadData {
    std::vector<uint8_t> input_data;
};

struct Prediction {
    size_t class_index = 0;
    float score = 0.0f;
};

struct OutputInferenceSummary {
    std::string stream_name;
    hailo_format_type_t format_type = HAILO_FORMAT_TYPE_AUTO;
    size_t element_count = 0;
    size_t completed_frames = 0;
    std::vector<size_t> top1_counts;
    std::vector<Prediction> first_frame_top_k;
    Prediction first_frame_top1;
    Prediction last_frame_top1;
    bool has_result = false;
};

void log_line(std::ostream &stream, const std::string &message)
{
    std::lock_guard<std::mutex> lock(g_log_mutex);
    stream << "[worker=" << g_worker_id << "][pid=" << ::getpid() << "] "
           << message << std::endl;
}

void log_info(const std::string &message)
{
    log_line(std::cout, message);
}

void log_error(const std::string &message)
{
    log_line(std::cerr, message);
}

int64_t unix_time_ms()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}

bool parse_unsigned(const char *text, uint64_t maximum, uint64_t &value)
{
    const auto text_length = std::strlen(text);
    if ((0 == text_length) || !std::all_of(text, text + text_length, [](unsigned char ch) {
            return std::isdigit(ch);
        })) {
        return false;
    }

    try {
        size_t parsed_length = 0;
        const auto parsed = std::stoull(text, &parsed_length, 10);
        if ((parsed_length != text_length) || (parsed > maximum)) {
            return false;
        }
        value = parsed;
        return true;
    } catch (const std::exception &) {
        return false;
    }
}

bool parse_size_environment(const char *name, bool allow_zero, size_t &value)
{
    const char *text = std::getenv(name);
    if (nullptr == text) {
        return true;
    }

    uint64_t parsed = 0;
    if (!parse_unsigned(text, std::numeric_limits<size_t>::max(), parsed) ||
        (!allow_zero && (0 == parsed))) {
        std::cerr << "Invalid " << name << " value: " << text << std::endl;
        return false;
    }
    value = static_cast<size_t>(parsed);
    return true;
}

bool is_valid_worker_id(const std::string &worker_id)
{
    return !worker_id.empty() && std::all_of(worker_id.begin(), worker_id.end(), [](unsigned char ch) {
        return std::isalnum(ch) || ('_' == ch) || ('-' == ch) || ('.' == ch);
    });
}

void print_usage(const char *program)
{
    std::cerr
        << "Usage: " << program << " <hef_path> <image_path> <labels_json> "
        << "<frame_count> <batch_size> <priority> <timeout_ms> <threshold> "
        << "[<worker_id> <barrier_dir>]\n\n"
        << "Without the optional arguments, one direct-mode worker starts immediately.\n"
        << "With them, the worker creates <barrier_dir>/ready.<worker_id> and waits\n"
        << "for <barrier_dir>/start before beginning inference." << std::endl;
}

bool parse_options(int argc, char **argv, Options &options)
{
    if ((9 != argc) && (11 != argc)) {
        print_usage(argv[0]);
        return false;
    }

    uint64_t frame_count = 0;
    uint64_t batch_size = 0;
    uint64_t priority = 0;
    uint64_t timeout_ms = 0;
    uint64_t threshold = 0;

    const bool valid_numbers =
        parse_unsigned(argv[4], std::numeric_limits<size_t>::max(), frame_count) &&
        parse_unsigned(argv[5], std::numeric_limits<uint16_t>::max(), batch_size) &&
        parse_unsigned(argv[6], std::numeric_limits<uint8_t>::max(), priority) &&
        parse_unsigned(argv[7], std::numeric_limits<uint32_t>::max(), timeout_ms) &&
        parse_unsigned(argv[8], std::numeric_limits<uint32_t>::max(), threshold);

    if (!valid_numbers || (0 == frame_count) || (0 == batch_size)) {
        std::cerr << "Invalid numeric argument: frame_count and batch_size must be non-zero, "
                  << "and every value must fit its HailoRT parameter type." << std::endl;
        return false;
    }

    options.hef_path = argv[1];
    options.image_path = argv[2];
    options.labels_path = argv[3];
    options.frame_count = static_cast<size_t>(frame_count);
    options.batch_size = static_cast<uint16_t>(batch_size);
    options.priority = static_cast<uint8_t>(priority);
    options.timeout_ms = static_cast<uint32_t>(timeout_ms);
    options.threshold = static_cast<uint32_t>(threshold);

    if (!parse_size_environment("HAILO_RESULT_TOP_K", false, options.result_top_k) ||
        !parse_size_environment("HAILO_RESULT_LOG_EVERY", true,
            options.result_log_every)) {
        return false;
    }

    if (11 == argc) {
        g_worker_id = argv[9];
        if (!is_valid_worker_id(g_worker_id)) {
            std::cerr << "Invalid worker_id. Use only letters, digits, '_', '-' or '.'." << std::endl;
            return false;
        }
        options.use_barrier = true;
        options.barrier_dir = argv[10];
        if (options.barrier_dir.empty()) {
            std::cerr << "barrier_dir must not be empty." << std::endl;
            return false;
        }
    }

    return true;
}

Expected<std::unique_ptr<VDevice>> create_direct_vdevice()
{
    hailo_vdevice_params_t params;
    const auto status = hailo_init_vdevice_params(&params);
    if (HAILO_SUCCESS != status) {
        log_error("hailo_init_vdevice_params failed, status=" + std::to_string(status));
        return make_unexpected(status);
    }

    params.device_count = DEVICE_COUNT;
    params.group_id = HAILO_UNIQUE_VDEVICE_GROUP_ID;
    params.multi_process_service = false;
    params.scheduling_algorithm = HAILO_SCHEDULING_ALGORITHM_ROUND_ROBIN;

    log_info("creating VDevice: direct_mode=1 multi_process_service=0 device_count=1");
    return VDevice::create(params);
}

Expected<std::shared_ptr<ConfiguredNetworkGroup>> configure_network_group(
    const Options &options, VDevice &vdevice)
{
    auto hef = Hef::create(options.hef_path);
    if (!hef) {
        return make_unexpected(hef.status());
    }

    auto configure_params = vdevice.create_configure_params(hef.value());
    if (!configure_params) {
        return make_unexpected(configure_params.status());
    }

    for (auto &network_group_entry : configure_params.value()) {
        network_group_entry.second.batch_size = options.batch_size;
    }

    auto network_groups = vdevice.configure(hef.value(), configure_params.value());
    if (!network_groups) {
        return make_unexpected(network_groups.status());
    }
    if (1 != network_groups->size()) {
        log_error("expected exactly one configured network group, got " +
            std::to_string(network_groups->size()));
        return make_unexpected(HAILO_INTERNAL_FAILURE);
    }

    auto network_group = network_groups->at(0);
    auto status = network_group->set_scheduler_priority(options.priority);
    if (HAILO_SUCCESS != status) {
        return make_unexpected(status);
    }
    status = network_group->set_scheduler_timeout(std::chrono::milliseconds(options.timeout_ms));
    if (HAILO_SUCCESS != status) {
        return make_unexpected(status);
    }
    status = network_group->set_scheduler_threshold(options.threshold);
    if (HAILO_SUCCESS != status) {
        return make_unexpected(status);
    }

    return network_group;
}

hailo_status wait_at_file_barrier(const Options &options)
{
    if (!options.use_barrier) {
        return HAILO_SUCCESS;
    }

    std::error_code error;
    fs::create_directories(options.barrier_dir, error);
    if (error) {
        log_error("failed to create barrier directory: " + error.message());
        return HAILO_FILE_OPERATION_FAILURE;
    }

    const auto ready_path = options.barrier_dir / ("ready." + g_worker_id);
    const auto temporary_ready_path = options.barrier_dir /
        (".ready." + g_worker_id + "." + std::to_string(::getpid()));
    const auto start_path = options.barrier_dir / "start";

    {
        std::ofstream ready_file(temporary_ready_path);
        if (!ready_file) {
            log_error("failed to create temporary ready file: " + temporary_ready_path.string());
            return HAILO_FILE_OPERATION_FAILURE;
        }
        ready_file << ::getpid() << '\n';
        if (!ready_file) {
            log_error("failed to write temporary ready file: " + temporary_ready_path.string());
            return HAILO_FILE_OPERATION_FAILURE;
        }
    }

    fs::rename(temporary_ready_path, ready_path, error);
    if (error) {
        log_error("failed to publish ready file: " + error.message());
        return HAILO_FILE_OPERATION_FAILURE;
    }

    log_info("barrier-ready path=" + ready_path.string());
    const auto deadline = std::chrono::steady_clock::now() + BARRIER_TIMEOUT;
    while (std::chrono::steady_clock::now() < deadline) {
        error.clear();
        if (fs::exists(start_path, error)) {
            log_info("barrier-released path=" + start_path.string());
            return HAILO_SUCCESS;
        }
        if (error) {
            log_error("failed to inspect start file: " + error.message());
            return HAILO_FILE_OPERATION_FAILURE;
        }
        std::this_thread::sleep_for(BARRIER_POLL_INTERVAL);
    }

    log_error("timed out waiting for barrier start file");
    return HAILO_TIMEOUT;
}

const char *format_type_name(hailo_format_type_t format_type)
{
    switch (format_type) {
    case HAILO_FORMAT_TYPE_UINT8:
        return "UINT8";
    case HAILO_FORMAT_TYPE_UINT16:
        return "UINT16";
    case HAILO_FORMAT_TYPE_FLOAT32:
        return "FLOAT32";
    case HAILO_FORMAT_TYPE_AUTO:
        return "AUTO";
    default:
        return "UNKNOWN";
    }
}

size_t format_element_size(hailo_format_type_t format_type)
{
    switch (format_type) {
    case HAILO_FORMAT_TYPE_UINT8:
        return sizeof(uint8_t);
    case HAILO_FORMAT_TYPE_UINT16:
        return sizeof(uint16_t);
    case HAILO_FORMAT_TYPE_FLOAT32:
        return sizeof(float);
    default:
        return 0;
    }
}

std::string log_safe_label(const std::vector<std::string> &labels, size_t class_index)
{
    std::string label = (class_index < labels.size() && !labels[class_index].empty()) ?
        labels[class_index] : "<unknown>";

    for (auto &character : label) {
        const auto byte = static_cast<unsigned char>(character);
        if ('"' == character) {
            character = '\'';
        } else if (std::iscntrl(byte)) {
            character = ' ';
        }
    }
    return label;
}

const hailo_quant_info_t &quant_info_for_element(
    const std::vector<hailo_quant_info_t> &quant_infos,
    const hailo_quant_info_t &fallback, size_t element_index, size_t element_count)
{
    if (quant_infos.size() == element_count) {
        return quant_infos[element_index];
    }
    if (!quant_infos.empty()) {
        return quant_infos.front();
    }
    return fallback;
}

bool decode_classification_scores(const std::vector<uint8_t> &data,
    hailo_format_type_t format_type, const hailo_quant_info_t &fallback_quant_info,
    const std::vector<hailo_quant_info_t> &quant_infos, std::vector<float> &scores)
{
    const size_t element_size = format_element_size(format_type);
    if ((0 == element_size) || (data.size() % element_size != 0)) {
        return false;
    }

    const size_t element_count = data.size() / element_size;
    scores.resize(element_count);
    for (size_t index = 0; index < element_count; ++index) {
        float score = 0.0f;
        if (HAILO_FORMAT_TYPE_FLOAT32 == format_type) {
            std::memcpy(&score, data.data() + (index * element_size), sizeof(score));
        } else {
            const auto &quant_info = quant_info_for_element(quant_infos,
                fallback_quant_info, index, element_count);
            if (HAILO_FORMAT_TYPE_UINT8 == format_type) {
                const auto raw_value = data[index];
                score = (static_cast<float>(raw_value) - quant_info.qp_zp) *
                    quant_info.qp_scale;
            } else if (HAILO_FORMAT_TYPE_UINT16 == format_type) {
                uint16_t raw_value = 0;
                std::memcpy(&raw_value, data.data() + (index * element_size),
                    sizeof(raw_value));
                score = (static_cast<float>(raw_value) - quant_info.qp_zp) *
                    quant_info.qp_scale;
            }
        }

        if (!std::isfinite(score)) {
            return false;
        }
        scores[index] = score;
    }
    return !scores.empty();
}

std::vector<Prediction> select_top_k(const std::vector<float> &scores, size_t requested_k)
{
    const size_t result_count = std::min(requested_k, scores.size());
    std::vector<size_t> indices(scores.size());
    std::iota(indices.begin(), indices.end(), 0);
    std::partial_sort(indices.begin(), indices.begin() + result_count, indices.end(),
        [&scores](size_t lhs, size_t rhs) {
            if (scores[lhs] == scores[rhs]) {
                return lhs < rhs;
            }
            return scores[lhs] > scores[rhs];
        });

    std::vector<Prediction> predictions;
    predictions.reserve(result_count);
    for (size_t rank = 0; rank < result_count; ++rank) {
        predictions.push_back(Prediction{indices[rank], scores[indices[rank]]});
    }
    return predictions;
}

std::string prediction_fields(const Prediction &prediction,
    const std::vector<std::string> &labels, const std::string &prefix)
{
    std::ostringstream stream;
    stream << prefix << "_index=" << prediction.class_index
           << ' ' << prefix << "_score=" << std::fixed << std::setprecision(6)
           << prediction.score
           << ' ' << prefix << "_label=\""
           << log_safe_label(labels, prediction.class_index) << '"';
    return stream.str();
}

void log_first_frame_top_k(const OutputInferenceSummary &summary,
    const std::vector<std::string> &labels)
{
    std::ostringstream message;
    message << "inference-result-topk stream=" << summary.stream_name
            << " frame=0 k=" << summary.first_frame_top_k.size();
    for (size_t rank = 0; rank < summary.first_frame_top_k.size(); ++rank) {
        message << " rank" << (rank + 1) << "_index="
                << summary.first_frame_top_k[rank].class_index
                << " rank" << (rank + 1) << "_score=" << std::fixed
                << std::setprecision(6) << summary.first_frame_top_k[rank].score
                << " rank" << (rank + 1) << "_label=\""
                << log_safe_label(labels,
                    summary.first_frame_top_k[rank].class_index) << '"';
    }
    log_info(message.str());
}

void log_output_summary(const OutputInferenceSummary &summary,
    const std::vector<std::string> &labels, size_t expected_frames)
{
    if (!summary.has_result || summary.top1_counts.empty()) {
        log_error("inference-result-summary stream=" + summary.stream_name +
            " completed_frames=" + std::to_string(summary.completed_frames) +
            " expected_frames=" + std::to_string(expected_frames) +
            " result=unavailable");
        return;
    }

    const auto dominant = std::max_element(summary.top1_counts.begin(),
        summary.top1_counts.end());
    const size_t dominant_index = static_cast<size_t>(
        std::distance(summary.top1_counts.begin(), dominant));
    const size_t dominant_count = *dominant;
    const double consistency = (0 == summary.completed_frames) ? 0.0 :
        (100.0 * static_cast<double>(dominant_count) /
            static_cast<double>(summary.completed_frames));

    std::ostringstream message;
    message << "inference-result-summary stream=" << summary.stream_name
            << " format=" << format_type_name(summary.format_type)
            << " elements=" << summary.element_count
            << " completed_frames=" << summary.completed_frames
            << " expected_frames=" << expected_frames
            << " dominant_top1_index=" << dominant_index
            << " dominant_top1_count=" << dominant_count
            << " dominant_top1_consistency_pct=" << std::fixed
            << std::setprecision(2) << consistency
            << " dominant_top1_label=\""
            << log_safe_label(labels, dominant_index) << "\" "
            << prediction_fields(summary.first_frame_top1, labels, "first_top1")
            << ' ' << prediction_fields(summary.last_frame_top1, labels, "last_top1");
    log_info(message.str());
}

void write_all(InputVStream &input, std::vector<uint8_t> &data,
    hailo_status &status, size_t stream_index, size_t frame_count)
{
    log_info("input-stream-start index=" + std::to_string(stream_index));
    for (size_t frame = 0; frame < frame_count; ++frame) {
        status = input.write(MemoryView(data.data(), data.size()));
        if (HAILO_SUCCESS != status) {
            log_error("input write failed: stream=" + std::to_string(stream_index) +
                " frame=" + std::to_string(frame) + " status=" + std::to_string(status));
            return;
        }
    }
    status = HAILO_SUCCESS;
    log_info("input-stream-complete index=" + std::to_string(stream_index) +
        " frames=" + std::to_string(frame_count));
}

void read_all(OutputVStream &output, hailo_status &status,
    size_t stream_index, size_t frame_count, const std::vector<std::string> &labels,
    size_t result_top_k, size_t result_log_every,
    OutputInferenceSummary &summary)
{
    std::vector<uint8_t> data(output.get_frame_size());
    std::vector<float> scores;
    const auto &output_info = output.get_info();
    const auto &quant_infos = output.get_quant_infos();
    auto format_type = output.get_user_buffer_format().type;
    if (HAILO_FORMAT_TYPE_AUTO == format_type) {
        format_type = output_info.format.type;
    }

    const size_t element_size = format_element_size(format_type);
    if ((0 == element_size) || data.empty() || (data.size() % element_size != 0)) {
        log_error("unsupported output format: stream=" + output.name() +
            " format=" + format_type_name(format_type) +
            " frame_bytes=" + std::to_string(data.size()));
        status = HAILO_INVALID_ARGUMENT;
        return;
    }

    summary.stream_name = output.name();
    summary.format_type = format_type;
    summary.element_count = data.size() / element_size;
    summary.top1_counts.assign(summary.element_count, 0);
    log_info("output-stream-start index=" + std::to_string(stream_index) +
        " name=" + summary.stream_name +
        " format=" + format_type_name(format_type) +
        " frame_bytes=" + std::to_string(data.size()) +
        " elements=" + std::to_string(summary.element_count) +
        " quant_infos=" + std::to_string(quant_infos.size()));

    for (size_t frame = 0; frame < frame_count; ++frame) {
        status = output.read(MemoryView(data.data(), data.size()));
        if (HAILO_SUCCESS != status) {
            log_error("output read failed: stream=" + std::to_string(stream_index) +
                " frame=" + std::to_string(frame) + " status=" + std::to_string(status));
            return;
        }

        if (!decode_classification_scores(data, format_type,
            output_info.quant_info, quant_infos, scores)) {
            log_error("output decode failed: stream=" + std::to_string(stream_index) +
                " frame=" + std::to_string(frame) +
                " format=" + format_type_name(format_type));
            status = HAILO_INVALID_OPERATION;
            return;
        }

        const auto predictions = select_top_k(scores, result_top_k);
        if (predictions.empty()) {
            log_error("output has no classification elements: stream=" +
                std::to_string(stream_index));
            status = HAILO_INVALID_OPERATION;
            return;
        }

        const auto &top1 = predictions.front();
        summary.completed_frames++;
        summary.top1_counts[top1.class_index]++;
        summary.last_frame_top1 = top1;
        if (!summary.has_result) {
            summary.has_result = true;
            summary.first_frame_top1 = top1;
            summary.first_frame_top_k = predictions;
            log_first_frame_top_k(summary, labels);
        }

        if ((0 != result_log_every) &&
            (((frame + 1) % result_log_every == 0) || (frame + 1 == frame_count))) {
            log_info("inference-result stream=" + summary.stream_name +
                " frame=" + std::to_string(frame) + " " +
                prediction_fields(top1, labels, "top1"));
        }
    }
    status = HAILO_SUCCESS;
    log_info("output-stream-complete index=" + std::to_string(stream_index) +
        " frames=" + std::to_string(frame_count));
}

hailo_status infer(std::vector<InputVStream> &input_streams,
    std::vector<OutputVStream> &output_streams, ThreadData &thread_data,
    size_t frame_count, const std::vector<std::string> &labels,
    size_t result_top_k, size_t result_log_every)
{
    std::vector<hailo_status> input_status(input_streams.size(), HAILO_UNINITIALIZED);
    std::vector<hailo_status> output_status(output_streams.size(), HAILO_UNINITIALIZED);
    std::vector<std::thread> input_threads;
    std::vector<std::thread> output_threads;
    std::vector<OutputInferenceSummary> output_summaries(output_streams.size());
    input_threads.reserve(input_streams.size());
    output_threads.reserve(output_streams.size());

    for (size_t index = 0; index < output_streams.size(); ++index) {
        output_threads.emplace_back(read_all, std::ref(output_streams[index]),
            std::ref(output_status[index]), index, frame_count, std::cref(labels),
            result_top_k, result_log_every, std::ref(output_summaries[index]));
    }
    for (size_t index = 0; index < input_streams.size(); ++index) {
        input_threads.emplace_back(write_all, std::ref(input_streams[index]),
            std::ref(thread_data.input_data), std::ref(input_status[index]), index, frame_count);
    }

    for (auto &thread : input_threads) {
        thread.join();
    }
    for (auto &thread : output_threads) {
        thread.join();
    }

    for (const auto &summary : output_summaries) {
        log_output_summary(summary, labels, frame_count);
    }

    for (const auto status : input_status) {
        if (HAILO_SUCCESS != status) {
            return status;
        }
    }
    for (const auto status : output_status) {
        if (HAILO_SUCCESS != status) {
            return status;
        }
    }
    return HAILO_SUCCESS;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, options)) {
        return HAILO_INVALID_ARGUMENT;
    }

    log_info("process-start direct_mode=1");

    std::vector<std::string> labels;
    try {
        labels = util::load_labels_jsoncpp(options.labels_path);
        log_info("labels-loaded count=" + std::to_string(labels.size()));
    } catch (const std::exception &exception) {
        log_error("failed to load labels: " + std::string(exception.what()));
        return HAILO_INVALID_ARGUMENT;
    }

    auto vdevice = create_direct_vdevice();
    if (!vdevice) {
        log_error("VDevice creation failed, status=" + std::to_string(vdevice.status()));
        return vdevice.status();
    }

    auto network_group = configure_network_group(options, *vdevice.value());
    if (!network_group) {
        log_error("network configuration failed, status=" + std::to_string(network_group.status()));
        return network_group.status();
    }

    auto vstreams = VStreamsBuilder::create_vstreams(*network_group.value(), {}, FORMAT_TYPE);
    if (!vstreams) {
        log_error("VStream creation failed, status=" + std::to_string(vstreams.status()));
        return vstreams.status();
    }
    if (1 != vstreams->first.size()) {
        log_error("this ResNet test worker requires exactly one input VStream, got " +
            std::to_string(vstreams->first.size()));
        return HAILO_INVALID_OPERATION;
    }
    if (vstreams->second.empty()) {
        log_error("no output VStreams were created");
        return HAILO_INVALID_OPERATION;
    }

    auto &input_vstream = vstreams->first.front();
    const auto input_info = input_vstream.get_info();
    const float qp_scale = input_info.quant_info.qp_scale;
    const float qp_zp = input_info.quant_info.qp_zp;

    const auto image = cv::imread(options.image_path, cv::IMREAD_COLOR);
    if (image.empty()) {
        log_error("failed to load image: " + options.image_path);
        return HAILO_INVALID_ARGUMENT;
    }

    cv::Mat preprocessed;
    try {
        preprocessed = util::preprocess_image_resnet_uint8(image, qp_scale, qp_zp);
    } catch (const std::exception &exception) {
        log_error("image preprocessing failed: " + std::string(exception.what()));
        return HAILO_INVALID_ARGUMENT;
    }

    ThreadData thread_data;
    thread_data.input_data.resize(input_vstream.get_frame_size());
    const size_t image_bytes = preprocessed.total() * preprocessed.elemSize();
    if (!preprocessed.isContinuous()) {
        log_error("preprocessed image memory is not contiguous");
        return HAILO_INVALID_OPERATION;
    }
    if (thread_data.input_data.size() != image_bytes) {
        log_error("preprocessed image size mismatch: vstream=" +
            std::to_string(thread_data.input_data.size()) + " image=" +
            std::to_string(image_bytes));
        return HAILO_INVALID_OPERATION;
    }
    std::memcpy(thread_data.input_data.data(), preprocessed.data, image_bytes);

    log_info("configuration-complete inputs=" + std::to_string(vstreams->first.size()) +
        " outputs=" + std::to_string(vstreams->second.size()) +
        " frames=" + std::to_string(options.frame_count) +
        " result_top_k=" + std::to_string(options.result_top_k) +
        " result_log_every=" + std::to_string(options.result_log_every));

    const auto barrier_status = wait_at_file_barrier(options);
    if (HAILO_SUCCESS != barrier_status) {
        return barrier_status;
    }

    const auto start_time = std::chrono::steady_clock::now();
    const auto start_unix_ms = unix_time_ms();
    log_info("inference-start start_unix_ms=" + std::to_string(start_unix_ms));

    const auto status = infer(vstreams->first, vstreams->second,
        thread_data, options.frame_count, labels, options.result_top_k,
        options.result_log_every);
    const auto end_unix_ms = unix_time_ms();
    const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start_time).count();

    if (HAILO_SUCCESS != status) {
        log_error("inference-failed status=" + std::to_string(status) +
            " end_unix_ms=" + std::to_string(end_unix_ms) +
            " elapsed_ms=" + std::to_string(elapsed_ms));
        return status;
    }

    log_info("inference-complete status=0 end_unix_ms=" + std::to_string(end_unix_ms) +
        " elapsed_ms=" + std::to_string(elapsed_ms) +
        " frames=" + std::to_string(options.frame_count));
    return HAILO_SUCCESS;
}
