#include "util.hpp"

namespace fs = std::filesystem;

cv::Mat util::preprocess_image_resnet_uint8(const cv::Mat &image, float qp_scale, float qp_zp)
{
    // Fix height and width
    int target_height = 224;
    int target_width = 224;

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

// Helper: collect image paths
std::vector<std::string> util::collect_image_paths(const std::string &dir)
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

std::vector<std::string> util::load_labels_jsoncpp(const std::string &json_path)
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

void util::print_topK(const uint8_t *logits, size_t num_classes, std::vector<std::string> labels, size_t k)
{
    // Find top 3 indices
    if(k > num_classes){
        std::cerr << "Error K (" << k << ") is larger than the number of classes (" << num_classes << ")" << std::endl;
    }

    if (num_classes != 1000){
        std::cout << "Warning: expected 1000 classes, got "
                << num_classes << std::endl;
    }
    std::vector<int> indices(num_classes);
    std::iota(indices.begin(), indices.end(), 0);

    std::partial_sort(indices.begin(), indices.begin() + k, indices.end(),
        [&](int a, int b){
            return logits[a] > logits[b]; // descending
        });

    std::cout << "Top " << k << " predictions:" << std::endl;
    for (size_t i = 0; i < k; ++i){
        int idx = indices[i];
        float logit = logits[idx] / 256.0;

        std::string label = (idx < static_cast<int>(labels.size()))
                            ? labels[idx]
                            : std::string("<unknown>");

        std::cout << "  #" << (i + 1)
                << " idx=" << idx
                << " score=" << logit
                << " label=\"" << label << "\""
                << std::endl;
    }
}
