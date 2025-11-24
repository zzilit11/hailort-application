// HailoRT Inference Driver for ResNet 50

#include "hailo/hailort.hpp"

#include <iostream>
#include <opencv2/opencv.hpp>
#include <vector>
#include <filesystem>
#include <jsoncpp/json/json.h>
#include <fstream>
#include <algorithm>
#include <numeric>

#define HEF_FILE ("/home/rtoslab-alpha/workspace/hailort/resnet_v1_50.hef")
constexpr size_t FRAMES_COUNT = 6;
constexpr hailo_format_type_t FORMAT_TYPE = HAILO_FORMAT_TYPE_AUTO;

using namespace hailort;
namespace fs = std::filesystem;

cv::Mat preprocess_image_resnet_uint8(const cv::Mat &image,
                                      int target_height,
                                      int target_width,
                                      float qp_scale,
                                      float qp_zp)
{
    // Ensure 3-channel BGR
    cv::Mat img_bgr;
    if (image.channels() == 3) {
        img_bgr = image;
    } else if (image.channels() == 4) {
        cv::cvtColor(image, img_bgr, cv::COLOR_BGRA2BGR);
    } else if (image.channels() == 1) {
        cv::cvtColor(image, img_bgr, cv::COLOR_GRAY2BGR);
    } else {
        throw std::runtime_error("Unsupported number of channels in input image");
    }

    int h = img_bgr.rows;
    int w = img_bgr.cols;

    // 1. Scale shorter side to 256
    float scale = 256.0f / static_cast<float>(std::min(h, w));
    int new_h = static_cast<int>(std::round(h * scale));
    int new_w = static_cast<int>(std::round(w * scale));

    cv::Mat resized;
    cv::resize(img_bgr, resized, cv::Size(new_w, new_h), 0, 0, cv::INTER_LINEAR);

    // 2. Center crop
    int x = (new_w - target_width) / 2;
    int y = (new_h - target_height) / 2;
    cv::Rect crop(x, y, target_width, target_height);
    cv::Mat cropped = resized(crop); // CV_8UC3

    // 3. Convert to float32 and subtract ImageNet Caffe means
    cv::Mat float_image;
    cropped.convertTo(float_image, CV_32FC3, 1.0);

    const float mean[3] = {103.939f, 116.779f, 123.68f};
    std::vector<cv::Mat> channels(3);
    cv::split(float_image, channels);
    for (int c = 0; c < 3; ++c) {
        channels[c] = channels[c] - mean[c];
    }
    cv::merge(channels, float_image); // still CV_32FC3

    // 4. Quantize float_image -> uint8 using Hailo qp_scale / qp_zp
    cv::Mat quantized(target_height, target_width, CV_8UC3);
    float    *fptr = reinterpret_cast<float*>(float_image.data);
    uint8_t  *qptr = quantized.data;

    size_t total_elements = static_cast<size_t>(target_height) *
                            static_cast<size_t>(target_width) * 3;

    for (size_t i = 0; i < total_elements; ++i) {
        // Same formula as your TFLite path, but using Hailo scale/zp
        int32_t q = static_cast<int32_t>(std::round(fptr[i] / qp_scale) + qp_zp);
        q = std::max(0, std::min(255, q));
        qptr[i] = static_cast<uint8_t>(q);
    }

    return quantized; // CV_8UC3, quantized, ready to memcpy into Hailo input buffer
}

cv::Mat preprocess_image_resnet_int8(cv::Mat &image, int target_height, int target_width)
{
    // === 1. 이미지 리사이즈 및 중앙 크롭 (기존과 동일) ===
    int h = image.rows, w = image.cols;
    float scale_factor = 256.0f / std::min(h, w);
    int new_h = static_cast<int>(h * scale_factor);
    int new_w = static_cast<int>(w * scale_factor);

    cv::Mat resized;
    cv::resize(image, resized, cv::Size(new_w, new_h), 0, 0, cv::INTER_LINEAR);

    int x = (new_w - target_width) / 2;
    int y = (new_h - target_height) / 2;
    cv::Rect crop(x, y, target_width, target_height);
    cv::Mat cropped = resized(crop); // 최종적으로 모델에 들어갈 이미지 (CV_8UC3, 0-255 범위)

    // === 2. INT8 양자화 수행 ===
    // 로그에서 확인한 입력 텐서의 양자화 파라미터
    const float scale = 0.003921567928045988f;
    const float zero_point = -128.0f;

    // 결과를 저장할 int8 타입의 Mat 객체 생성 (CV_8SC3: signed 8-bit, 3 channels)
    cv::Mat int8_image(target_height, target_width, CV_8SC3);

    // 각 픽셀에 대해 양자화 공식 적용
    for (int r = 0; r < cropped.rows; ++r) {
        for (int c = 0; c < cropped.cols; ++c) {
            for (int k = 0; k < 3; ++k) { // B, G, R 채널 순회
                // a. 0-255(uint8) 픽셀 값을 0.0-1.0(float) 범위로 정규화
                float real_value = static_cast<float>(cropped.at<cv::Vec3b>(r, c)[k]) / 255.0f;

                // b. 양자화 공식 적용: quantized = (real_value / scale) + zero_point
                float quantized_float = (real_value / scale) + zero_point;

                // c. 반올림 후 int8 범위[-128, 127]로 클램핑(clamping)
                int32_t quantized_int = static_cast<int32_t>(std::round(quantized_float));
                quantized_int = std::max(-128, std::min(127, quantized_int));

                // d. 최종 int8 값을 결과 이미지에 저장
                int8_image.at<cv::Vec<int8_t, 3>>(r, c)[k] = static_cast<int8_t>(quantized_int);
            }
        }
    }

    return int8_image;
}

// Helper: collect image paths
std::vector<std::string> collect_image_paths(const std::string &dir)
{
    std::vector<std::string> paths;
    for (const auto &entry : fs::directory_iterator(dir)) {
        if (!entry.is_regular_file())
            continue;
        auto path = entry.path();
        if (path.extension() == ".png" &&
            path.filename().string().rfind("_images_", 0) == 0) {
            paths.push_back(path.string());
        }
    }
    std::sort(paths.begin(), paths.end());
    return paths;
}

std::vector<std::string> load_labels_jsoncpp(const std::string &json_path)
{
    std::ifstream ifs(json_path);
    if (!ifs.is_open()) {
        throw std::runtime_error("Failed to open label JSON: " + json_path);
    }

    Json::CharReaderBuilder builder;
    Json::Value root;
    std::string errs;

    if (!Json::parseFromStream(builder, ifs, &root, &errs)) {
        throw std::runtime_error("JSON parsing error: " + errs);
    }

    if (!root.isObject()) {
        throw std::runtime_error("Expected JSON root to be an object");
    }

    std::vector<std::string> labels;
    labels.resize(root.size()); // we’ll grow if needed

    for (auto it = root.begin(); it != root.end(); ++it) {
        const std::string key = it.name();
        int idx = std::stoi(key);

        const Json::Value &arr = *it;
        if (!arr.isArray() || arr.size() < 2) {
            throw std::runtime_error("Label entry for key " + key +
                                     " is not an array of size >= 2");
        }

        // arr[0] = "n01440764" (WNID)
        // arr[1] = "tench"     (human label)
        if (!arr[1].isString()) {
            throw std::runtime_error("Second element for key " + key +
                                     " is not a string");
        }

        if (idx >= static_cast<int>(labels.size())) {
            labels.resize(idx + 1);
        }
        labels[idx] = arr[1].asString();
    }

    return labels;
}

struct TopKEntry {
    int index;
    float score;
};

std::vector<TopKEntry> topk(const float *logits, size_t length, size_t k)
{
    if (k > length) k = length;

    std::vector<int> indices(length);
    std::iota(indices.begin(), indices.end(), 0);

    std::partial_sort(indices.begin(), indices.begin() + k, indices.end(),
        [&](int a, int b) {
            return logits[a] > logits[b]; // descending
        });

    std::vector<TopKEntry> result;
    result.reserve(k);
    for (size_t i = 0; i < k; ++i) {
        int idx = indices[i];
        result.push_back({idx, logits[idx]});
    }
    return result;
}

int main() {
    auto vdevice = VDevice::create();
    if(!vdevice) {
        std::cerr << "Failed to create vdevice, status = " << vdevice.status() << std::endl;
        return vdevice.status();
    }

    auto model = Hef::create(HEF_FILE);
    if(!model) {
        std::cerr << "Failed to create hef from file " << HEF_FILE << ", status = " << model.status() << std::endl;
        return model.status();
    }

    auto configure_params = vdevice.value()->create_configure_params(model.value());
    if(!configure_params) {
        std::cerr << "Failed to create configure params, status = " << configure_params.status() << std::endl;
        return configure_params.status();
    }

    auto network_groups = vdevice.value()->configure(model.value(), configure_params.value());
    if(!network_groups) {
        std::cerr << "Failed to configure network groups, status = " << network_groups.status() << std::endl;
        return network_groups.status();
    }

    if(network_groups.value().size() != 1) {
        std::cerr << "Invalid amount of network groups: " << network_groups.value().size() << std::endl;
        return HAILO_INTERNAL_FAILURE;
    }  
    auto network_group = network_groups.value().at(0);

    auto input_params = network_group->make_input_vstream_params({}, FORMAT_TYPE, HAILO_DEFAULT_VSTREAM_TIMEOUT_MS, HAILO_DEFAULT_VSTREAM_QUEUE_SIZE);
    if(!input_params) {
        std::cerr << "Failed to make input vstream params, status = " << input_params.status() << std::endl;
        return input_params.status();  
    }
    
    auto output_params = network_group->make_output_vstream_params({}, FORMAT_TYPE, HAILO_DEFAULT_VSTREAM_TIMEOUT_MS, HAILO_DEFAULT_VSTREAM_QUEUE_SIZE);
    if(!output_params) {
        std::cerr << "Failed to make output vstream params, status = " << output_params.status() << std::endl;
        return output_params.status();
    }

    // 5. Create inference pipeline
    auto pipeline_exp = InferVStreams::create(*network_group,
                                              input_params.value(),
                                              output_params.value());
    if (!pipeline_exp) {
        std::cerr << "Failed to create inference pipeline, status = "
                  << pipeline_exp.status() << std::endl;
        return pipeline_exp.status();
    }

    auto pipeline = std::make_unique<InferVStreams>(std::move(pipeline_exp.value()));

    // 6. Prepare input/output buffers and MemoryViews
    std::map<std::string, std::vector<uint8_t>> input_buffers;
    std::map<std::string, std::vector<uint8_t>> output_buffers;
    std::map<std::string, MemoryView> input_views;
    std::map<std::string, MemoryView> output_views;

    // Assume single input vstream for ResNet50
    int input_height = 224; // adjust if your HEF uses a different size
    int input_width  = 224;

    auto &first_input_vstream = pipeline->get_input_vstreams().front().get();
    auto input_info = first_input_vstream.get_info();
    float qp_scale = input_info.quant_info.qp_scale;
    float qp_zp    = input_info.quant_info.qp_zp;

    for (auto &input_vstream_ref : pipeline->get_input_vstreams()) {
        auto &input_vstream = input_vstream_ref.get();
        std::string name = input_vstream.name();
        size_t frame_size = input_vstream.get_frame_size();

        std::cout << "Input vstream \"" << name
                  << "\" frame size: " << frame_size << " bytes" << std::endl;

        input_buffers[name] = std::vector<uint8_t>(frame_size, 0);
        input_views.emplace(name,
            MemoryView(input_buffers[name].data(), input_buffers[name].size()));
    }

    for (auto &output_vstream_ref : pipeline->get_output_vstreams()) {
        auto &output_vstream = output_vstream_ref.get();
        std::string name = output_vstream.name();
        size_t frame_size = output_vstream.get_frame_size();

        std::cout << "Output vstream \"" << name
                  << "\" frame size: " << frame_size << " bytes" << std::endl;

        output_buffers[name] = std::vector<uint8_t>(frame_size, 0);
        std::cout << "Allocated output buffer of size " << output_buffers[name].size() << " bytes for stream '" << name << "'" << std::endl;
        output_views.emplace(name,
            MemoryView(output_buffers[name].data(), output_buffers[name].size()));
    }

    // Collect image paths
    std::string image_dir = "/home/rtoslab-alpha/workspace/hailort/images";
    auto image_paths = collect_image_paths(image_dir);
    if (image_paths.empty()) {
        std::cerr << "No images found in " << image_dir << std::endl;
        return -1;
    }

    // Load labels
    // Path to your label JSON
    std::string labels_path = "/home/rtoslab-alpha/workspace/hailort/resnet50_class_labels.json";
    std::vector<std::string> labels;
    try {
        labels = load_labels_jsoncpp(labels_path);
        std::cout << "Loaded " << labels.size() << " labels from " << labels_path << std::endl;
    } catch (const std::exception &e) {
        std::cerr << "Error loading labels: " << e.what() << std::endl;
        return -1;
    }

    size_t frames_count = std::min(FRAMES_COUNT, image_paths.size());

    for (size_t frame = 0; frame < frames_count; ++frame) {
        std::cout << "Running frame " << frame
                  << " with image: " << image_paths[frame] << std::endl;

        cv::Mat img = cv::imread(image_paths[frame], cv::IMREAD_COLOR);
        if (img.empty()) {
            std::cerr << "Failed to load image: "
                      << image_paths[frame] << std::endl;
            return -1;
        }

        cv::Mat preprocessed =
            preprocess_image_resnet_uint8(img, input_height, input_width, qp_scale, qp_zp); // HWC, CV_8UC3

        // Copy into the single input buffer (assume HWC interleaved to match HEF)
        auto &first_input_buffer = input_buffers.begin()->second;
        if (first_input_buffer.size() != preprocessed.total() * preprocessed.channels()) {
            std::cerr << "Size mismatch between preprocessed image and input buffer" << std::endl;
            std::cerr << "buffer size: " << first_input_buffer.size()
                      << ", image bytes: " << preprocessed.total() * preprocessed.channels()
                      << std::endl;
            return -1;
        }

        std::memcpy(first_input_buffer.data(),
                    preprocessed.data,
                    first_input_buffer.size());

        hailo_status status = pipeline->infer(input_views, output_views, 1);
        if (HAILO_SUCCESS != status) {
            std::cerr << "Failed to run inference, status = "
                      << status << std::endl;
            return status;
        }

        // Simple output dump
        if (!output_buffers.empty()) {
            auto &first_output = output_buffers.begin()->second;

            // Interpret output as float32 logits
            size_t num_classes = first_output.size();
            const uint8_t *scores = (first_output.data());

            if (num_classes == 0) {
                std::cerr << "Output buffer size is zero." << std::endl;
            } else {
                if (num_classes != 1000) {
                    std::cout << "Warning: expected 1000 classes, got "
                            << num_classes << std::endl;
                }

                // Find top 3 indices
                size_t k = std::min<size_t>(3, num_classes);
                std::vector<int> indices(num_classes);
                std::iota(indices.begin(), indices.end(), 0);

                std::partial_sort(indices.begin(), indices.begin() + k, indices.end(),
                    [&](int a, int b) {
                        return scores[a] > scores[b]; // descending
                    });

                std::cout << "Top " << k << " predictions:" << std::endl;
                for (size_t i = 0; i < k; ++i) {
                    int idx = indices[i];
                    float score = scores[idx];

                    std::string label = (idx < static_cast<int>(labels.size()))
                                        ? labels[idx]
                                        : std::string("<unknown>");

                    std::cout << "  #" << (i + 1)
                            << " idx=" << idx
                            << " score=" << score
                            << " label=\"" << label << "\""
                            << std::endl;
                }
            }
        }
    }

    std::cout << "Inference finished successfully." << std::endl;
    return HAILO_SUCCESS;
}