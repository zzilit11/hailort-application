/*
 * Filename: inference_driver.cpp
 *
 * @Author: Namcheol Lee
 * @Affiliation: Real-Time Operating System Laboratory, Seoul National University
 * @Created: 11/24/25
 * @Contact: {nclee}@redwood.snu.ac.kr
 *
 * @Description: Inferece driver example using HailoRT C++ API
 * 
 */

#include "hailo/hailort.hpp"

#include <iostream>
#include "util.hpp"

using namespace hailort;

int main(int argc, char *argv[]) {
    /* Receive arguments */
    if (argc != 4) {
        std::cerr << "Usage: " << argv[0]
            << "<model_path> <image_dir> <class_labels_path>"
            << std::endl;
        return -1;
    }
    
    const std::string model_path = argv[1];

    // Collect image paths
    std::string image_dir = argv[2];
    auto image_paths = util::collect_image_paths(image_dir);
    if (image_paths.empty()) {
        std::cerr << "No images found in " << image_dir << std::endl;
        return -1;
    }

    // Load labels
    std::string labels_path = argv[3];
    std::vector<std::string> labels;
    try {
        labels = util::load_labels_jsoncpp(labels_path);
        std::cout << "Loaded " << labels.size() << " labels from " << labels_path << std::endl;
    } catch (const std::exception &e) {
        std::cerr << "Error loading labels: " << e.what() << std::endl;
        return -1;
    }
    
    /* Create VDevice */
    Expected<std::unique_ptr<VDevice>> vdevice = VDevice::create();
    if(!vdevice) {
        std::cerr << "Failed to create vdevice, status = " << vdevice.status() << std::endl;
        return vdevice.status();
    }

    /* Load model */
    Expected<Hef> model = Hef::create(model_path);
    if(!model) {
        std::cerr << "Failed to create hef from file " << model_path << ", status = " << model.status() << std::endl;
        return model.status();
    }

    /* Create network group */
    // the number of networks are known in advance, can be retrieved by parsing the hef file
    // ConfigureNetworkParmas is a struct holding batch size (default 0), power_mode (performance), latency measurement flag
    // stream_params_by_name, and network_params_by_name
    Expected<NetworkGroupsParamsMap> configure_params = vdevice.value()->create_configure_params(model.value());
    if(!configure_params) {
        std::cerr << "Failed to create configure params, status = " << configure_params.status() << std::endl;
        return configure_params.status();
    }

    Expected<ConfiguredNetworkGroupVector> network_groups = vdevice.value()->configure(model.value(), configure_params.value());
    if(!network_groups) {
        std::cerr << "Failed to configure network groups, status = " << network_groups.status() << std::endl;
        return network_groups.status();
    }

    if(network_groups.value().size() != 1) {
        std::cerr << "Invalid amount of network groups: " << network_groups.value().size() << std::endl;
        return HAILO_INTERNAL_FAILURE;
    }  
    auto network_group = network_groups.value().at(0);

    /* Create InferVStreams */
    Expected<std::map<std::string, hailo_vstream_params_t>> input_vstream_params = 
        network_group->make_input_vstream_params({}, HAILO_FORMAT_TYPE_AUTO, 
            HAILO_DEFAULT_VSTREAM_TIMEOUT_MS, HAILO_DEFAULT_VSTREAM_QUEUE_SIZE);
    
    if(!input_vstream_params) {
        std::cerr << "Failed to make input vstream params, status = " << input_vstream_params.status() << std::endl;
        return input_vstream_params.status();  
    }
    
    Expected<std::map<std::string, hailo_vstream_params_t>> output_vstream_params = 
        network_group->make_output_vstream_params({}, HAILO_FORMAT_TYPE_FLOAT32,
            HAILO_DEFAULT_VSTREAM_TIMEOUT_MS, HAILO_DEFAULT_VSTREAM_QUEUE_SIZE);
    
    if(!output_vstream_params) {
        std::cerr << "Failed to make output vstream params, status = " << output_vstream_params.status() << std::endl;
        return output_vstream_params.status();
    }

    Expected<InferVStreams> infer_vstream = InferVStreams::create(*network_group,
                                              input_vstream_params.value(),
                                              output_vstream_params.value());
    
    if (!infer_vstream) {
        std::cerr << "Failed to create inference pipeline, status = "
                  << infer_vstream.status() << std::endl;
        return infer_vstream.status();
    }

    /* Allocate memory space */
    // Input
    std::map<std::string, std::vector<uint8_t>> input_buffers;
    std::map<std::string, MemoryView> input_views;

    // Assume single input vstream for ResNet50
    auto &input_vstream = infer_vstream->get_input_vstreams().front().get();
    std::string input_vstream_name = input_vstream.name();
    size_t input_frame_size = input_vstream.get_frame_size();
    std::cout << "Input vstream \"" << input_vstream_name
              << "\" frame size: " << input_frame_size << " bytes" << std::endl;
    input_buffers[input_vstream_name] = std::vector<uint8_t>(input_frame_size, 0);
    input_views.emplace(input_vstream_name,
        MemoryView(input_buffers[input_vstream_name].data(), input_buffers[input_vstream_name].size()));

    // Output
    std::map<std::string, std::vector<float>> output_buffers;
    std::map<std::string, MemoryView> output_views;

    auto &output_vstream = infer_vstream->get_output_vstreams().front().get();
    std::string output_vstream_name = output_vstream.name();
    size_t output_frame_size = output_vstream.get_frame_size();
    if (0 != (output_frame_size % sizeof(float))) {
        std::cerr << "Output frame size is not aligned to float32 elements" << std::endl;
        return HAILO_INTERNAL_FAILURE;
    }
    size_t output_elements = output_frame_size / sizeof(float);
    std::cout << "Output vstream \"" << output_vstream_name
              << "\" frame size: " << output_frame_size << " bytes"
              << " (" << output_elements << " float32 values)" << std::endl;
    output_buffers[output_vstream_name] = std::vector<float>(output_elements, 0.0f);
    output_views.emplace(output_vstream_name,
        MemoryView(output_buffers[output_vstream_name].data(), output_frame_size));

    /* Starting inference */
    // variables for quantization
    auto input_info = input_vstream.get_info();
    float qp_scale = input_info.quant_info.qp_scale;
    float qp_zp    = input_info.quant_info.qp_zp;
    for (size_t frame = 0; frame < image_paths.size(); ++frame) {
        /* Preprocessing */
        std::cout << "Running frame " << frame
                  << " with image: " << image_paths[frame] << std::endl;

        cv::Mat img = cv::imread(image_paths[frame], cv::IMREAD_COLOR);
        if (img.empty()) {
            std::cerr << "Failed to load image: "
                      << image_paths[frame] << std::endl;
            return -1;
        }

        cv::Mat preprocessed = util::preprocess_image_resnet_uint8(img, qp_scale, qp_zp);

        // Copy into the single input buffer (assume HWC interleaved to match HEF)
        auto &input = input_buffers[input_vstream_name];
        if (input.size() != preprocessed.total() * preprocessed.channels()) {
            std::cerr << "Size mismatch between preprocessed image and input buffer" << std::endl;
            std::cerr << "buffer size: " << input.size()
                      << ", image bytes: " << preprocessed.total() * preprocessed.channels()
                      << std::endl;
            return -1;
        }

        std::memcpy(input.data(), preprocessed.data, input.size());

        /* Inference */
        hailo_status status = infer_vstream->infer(input_views, output_views, 1);
        if (HAILO_SUCCESS != status) {
            std::cerr << "Failed to run inference, status = "
                      << status << std::endl;
            return status;
        }

        /* Postprocessing */
        auto &output = output_buffers[output_vstream_name];

        size_t num_classes = output.size();
        const float *scores = output.data();

        if (num_classes == 0) {
            std::cerr << "Output buffer size is zero." << std::endl;
        } else {
            // Print top-3 classes
            util::print_topK(scores, num_classes, labels, 3);
        }    
    }

    return HAILO_SUCCESS;
}