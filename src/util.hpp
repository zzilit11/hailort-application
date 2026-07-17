/*
 * Filename: util.hpp
 *
 * @Author: Namcheol Lee
 * @Affiliation: Real-Time Operating System Laboratory, Seoul National University
 * @Created: 11/24/25
 * @Contact: {nclee}@redwood.snu.ac.kr
 *
 * @Description: Headers of utility functions for inference driver
 * 
 */

#include <opencv2/opencv.hpp>
#include <vector>
#include <filesystem>
#include <jsoncpp/json/json.h>
#include <fstream>
#include <algorithm>
#include <numeric>

#ifndef _UTIL_H_
#define _UTIL_H_

namespace util{
    cv::Mat preprocess_image_resnet_uint8(const cv::Mat &image, float qp_scale, float qp_zp);

    std::vector<std::string> collect_image_paths(const std::string &dir);

    std::vector<std::string> load_labels_jsoncpp(const std::string &json_path);

    void print_topK(const float *scores, size_t length, const std::vector<std::string> &labels, size_t k);
    void print_topK(const uint8_t *logits, size_t length, const std::vector<std::string> &labels, size_t k);
} // namespace util


#endif // _UTIL_H_
