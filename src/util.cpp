/*
 * Filename: util.cpp
 *
 * @Author: Namcheol Lee
 * @Affiliation: Real-Time Operating System Laboratory, Seoul National University
 * @Created: 11/24/25
 * @Contact: {nclee}@redwood.snu.ac.kr
 *
 * @Description: Implementation of utility functions for inference driver
 * 
 */

#include "util.hpp"

#include <cmath>
#include <iostream>
#include <stdexcept>

namespace fs = std::filesystem;

namespace {
constexpr int RESNET_INPUT_HEIGHT = 224;
constexpr int RESNET_INPUT_WIDTH = 224;

cv::Mat ensure_bgr_3ch(const cv::Mat &image)
{
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
    return img_bgr;
}

cv::Mat resize_or_center_crop_224(const cv::Mat &img_bgr)
{
    if ((img_bgr.rows == RESNET_INPUT_HEIGHT) && (img_bgr.cols == RESNET_INPUT_WIDTH)) {
        return img_bgr.clone();
    }

    const float scale = 256.0f / static_cast<float>(std::min(img_bgr.rows, img_bgr.cols));
    const int new_h = static_cast<int>(std::round(img_bgr.rows * scale));
    const int new_w = static_cast<int>(std::round(img_bgr.cols * scale));

    cv::Mat resized;
    cv::resize(img_bgr, resized, cv::Size(new_w, new_h), 0, 0, cv::INTER_LINEAR);

    const int x = (new_w - RESNET_INPUT_WIDTH) / 2;
    const int y = (new_h - RESNET_INPUT_HEIGHT) / 2;
    return resized(cv::Rect(x, y, RESNET_INPUT_WIDTH, RESNET_INPUT_HEIGHT)).clone();
}

bool is_raw_uint8_input(float qp_scale, float qp_zp)
{
    return (std::abs(qp_scale - 1.0f) < 1e-3f) && (std::abs(qp_zp) < 1e-3f);
}
} // namespace

cv::Mat util::preprocess_image_resnet_uint8(const cv::Mat &image, float qp_scale, float qp_zp)
{
    cv::Mat img_bgr = ensure_bgr_3ch(image);
    cv::Mat cropped = resize_or_center_crop_224(img_bgr);

    if (is_raw_uint8_input(qp_scale, qp_zp)) {
        cv::Mat rgb;
        cv::cvtColor(cropped, rgb, cv::COLOR_BGR2RGB);
        return rgb;
    }

    cv::Mat float_image;
    cropped.convertTo(float_image, CV_32FC3, 1.0);

    const float mean[3] = {103.939f, 116.779f, 123.68f};
    std::vector<cv::Mat> channels(3);
    cv::split(float_image, channels);
    for (int c = 0; c < 3; ++c) {
        channels[c] = channels[c] - mean[c];
    }
    cv::merge(channels, float_image);

    cv::Mat quantized(RESNET_INPUT_HEIGHT, RESNET_INPUT_WIDTH, CV_8UC3);
    float *fptr = reinterpret_cast<float*>(float_image.data);
    uint8_t *qptr = quantized.data;

    const size_t total_elements = static_cast<size_t>(RESNET_INPUT_HEIGHT) *
                                  static_cast<size_t>(RESNET_INPUT_WIDTH) * 3;

    for (size_t i = 0; i < total_elements; ++i) {
        int32_t q = static_cast<int32_t>(std::round(fptr[i] / qp_scale) + qp_zp);
        q = std::max(0, std::min(255, q));
        qptr[i] = static_cast<uint8_t>(q);
    }

    return quantized;
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

void util::print_topK(const float *scores, size_t num_classes, const std::vector<std::string> &labels, size_t k)
{
    if (k > num_classes) {
        std::cerr << "Error K (" << k << ") is larger than the number of classes (" << num_classes << ")" << std::endl;
        return;
    }

    if (num_classes != 1000) {
        std::cout << "Warning: expected 1000 classes, got "
                  << num_classes << std::endl;
    }

    std::vector<int> indices(num_classes);
    std::iota(indices.begin(), indices.end(), 0);

    std::partial_sort(indices.begin(), indices.begin() + k, indices.end(),
        [&](int a, int b) {
            return scores[a] > scores[b];
        });

    std::cout << "Top " << k << " predictions:" << std::endl;
    for (size_t i = 0; i < k; ++i) {
        int idx = indices[i];
        std::string label = (idx < static_cast<int>(labels.size()))
                            ? labels[idx]
                            : std::string("<unknown>");

        std::cout << "  #" << (i + 1)
                  << " idx=" << idx
                  << " score=" << scores[idx]
                  << " label=\"" << label << "\""
                  << std::endl;
    }
}

void util::print_topK(const uint8_t *logits, size_t num_classes, const std::vector<std::string> &labels, size_t k)
{
    std::vector<float> scores(num_classes);
    for (size_t i = 0; i < num_classes; ++i) {
        scores[i] = static_cast<float>(logits[i]) / 256.0f;
    }
    print_topK(scores.data(), scores.size(), labels, k);
}
