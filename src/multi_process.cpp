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
#include <cstdint>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

namespace fs = std::filesystem;
using namespace hailort;

namespace {

constexpr hailo_format_type_t FORMAT_TYPE = HAILO_FORMAT_TYPE_AUTO;
constexpr uint32_t DEVICE_COUNT = 1;
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
    bool use_barrier = false;
    fs::path barrier_dir;
};

struct ThreadData {
    std::vector<uint8_t> input_data;
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
    size_t stream_index, size_t frame_count)
{
    std::vector<uint8_t> data(output.get_frame_size());
    log_info("output-stream-start index=" + std::to_string(stream_index));
    for (size_t frame = 0; frame < frame_count; ++frame) {
        status = output.read(MemoryView(data.data(), data.size()));
        if (HAILO_SUCCESS != status) {
            log_error("output read failed: stream=" + std::to_string(stream_index) +
                " frame=" + std::to_string(frame) + " status=" + std::to_string(status));
            return;
        }
    }
    status = HAILO_SUCCESS;
    log_info("output-stream-complete index=" + std::to_string(stream_index) +
        " frames=" + std::to_string(frame_count));
}

hailo_status infer(std::vector<InputVStream> &input_streams,
    std::vector<OutputVStream> &output_streams, ThreadData &thread_data,
    size_t frame_count)
{
    std::vector<hailo_status> input_status(input_streams.size(), HAILO_UNINITIALIZED);
    std::vector<hailo_status> output_status(output_streams.size(), HAILO_UNINITIALIZED);
    std::vector<std::thread> input_threads;
    std::vector<std::thread> output_threads;
    input_threads.reserve(input_streams.size());
    output_threads.reserve(output_streams.size());

    for (size_t index = 0; index < output_streams.size(); ++index) {
        output_threads.emplace_back(read_all, std::ref(output_streams[index]),
            std::ref(output_status[index]), index, frame_count);
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

    try {
        const auto labels = util::load_labels_jsoncpp(options.labels_path);
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
        " frames=" + std::to_string(options.frame_count));

    const auto barrier_status = wait_at_file_barrier(options);
    if (HAILO_SUCCESS != barrier_status) {
        return barrier_status;
    }

    const auto start_time = std::chrono::steady_clock::now();
    const auto start_unix_ms = unix_time_ms();
    log_info("inference-start start_unix_ms=" + std::to_string(start_unix_ms));

    const auto status = infer(vstreams->first, vstreams->second,
        thread_data, options.frame_count);
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
