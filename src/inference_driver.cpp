// HailoRT Inference Driver for ResNet 50

#include "hailo/hailort.hpp"

#include <iostream>
#include "util.hpp"

using namespace hailort;

int main(int argc, char *argv[]) {
    /* Receive arguments */
    if (argc < 4) {
        std::cerr << "Usage: " << argv[0]
            << "<model_path> <image_dir> <class_labels_path>"
            << std::endl;
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
    auto vdevice = VDevice::create();
    if(!vdevice) {
        std::cerr << "Failed to create vdevice, status = " << vdevice.status() << std::endl;
        return vdevice.status();
    }

    /* Load model */
    auto model = Hef::create(model_path);
    if(!model) {
        std::cerr << "Failed to create hef from file " << model_path << ", status = " << model.status() << std::endl;
        return model.status();
    }

    /* Configure network */
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

    /* Create InferVStreams */
    auto input_params = network_group->make_input_vstream_params({}, HAILO_FORMAT_TYPE_AUTO, HAILO_DEFAULT_VSTREAM_TIMEOUT_MS, HAILO_DEFAULT_VSTREAM_QUEUE_SIZE);
    if(!input_params) {
        std::cerr << "Failed to make input vstream params, status = " << input_params.status() << std::endl;
        return input_params.status();  
    }
    
    auto output_params = network_group->make_output_vstream_params({}, HAILO_FORMAT_TYPE_AUTO, HAILO_DEFAULT_VSTREAM_TIMEOUT_MS, HAILO_DEFAULT_VSTREAM_QUEUE_SIZE);
    if(!output_params) {
        std::cerr << "Failed to make output vstream params, status = " << output_params.status() << std::endl;
        return output_params.status();
    }

    auto pipeline_exp = InferVStreams::create(*network_group,
                                              input_params.value(),
                                              output_params.value());
    if (!pipeline_exp) {
        std::cerr << "Failed to create inference pipeline, status = "
                  << pipeline_exp.status() << std::endl;
        return pipeline_exp.status();
    }

    auto pipeline = std::make_unique<InferVStreams>(std::move(pipeline_exp.value()));

    /* Prepare input/output buffers */
    std::map<std::string, std::vector<uint8_t>> input_buffers;
    std::map<std::string, std::vector<uint8_t>> output_buffers;
    std::map<std::string, MemoryView> input_views;
    std::map<std::string, MemoryView> output_views;

    // Assume single input vstream for ResNet50
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

    /* Starting inference */
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


        /* Inference */
        hailo_status status = pipeline->infer(input_views, output_views, 1);
        if (HAILO_SUCCESS != status) {
            std::cerr << "Failed to run inference, status = "
                      << status << std::endl;
            return status;
        }

        /* Postprocessing */
        if (!output_buffers.empty()) {
            auto &output = output_buffers.begin()->second;

            size_t num_classes = output.size();
            const uint8_t *logits = (output.data());

            if (num_classes == 0) {
                std::cerr << "Output buffer size is zero." << std::endl;
            } else {
                // Print top-3 classes
                util::print_topK(logits, num_classes, labels, 3);
            }    
        }
    }

    return HAILO_SUCCESS;
}