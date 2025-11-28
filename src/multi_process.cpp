/**
 * ResNet50 Multi-Process Infinite Inference Example
 * * - Uses HailoRT Multi-Process Service
 * - Runs infinite inference loop with real image data
 * - Based on multi_process_example_infinite.cpp and inference_driver.cpp
 **/

#include "hailo/hailort.hpp"
#include "util.hpp" // inference_driver.cpp에서 사용된 유틸리티 헤더

#include <iostream>
#include <thread>
#include <vector>
#include <opencv2/opencv.hpp>

constexpr size_t FRAMES_COUNT = 1000;
constexpr hailo_format_type_t FORMAT_TYPE = HAILO_FORMAT_TYPE_AUTO;
constexpr size_t MAX_LAYER_EDGES = 16;
constexpr uint32_t DEVICE_COUNT = 1;

using namespace hailort;

// 스레드에 전달할 데이터 구조체
struct ThreadData {
    std::vector<uint8_t> input_data;      // 전처리된 이미지 데이터
    std::vector<std::string> labels;      // 클래스 라벨
};

Expected<std::shared_ptr<ConfiguredNetworkGroup>> configure_network_group(const std::string &hef_path, VDevice &vdevice)
{
    auto hef = Hef::create(hef_path);
    if (!hef) {
        return make_unexpected(hef.status());
    }

    auto configure_params = vdevice.create_configure_params(hef.value());
    if (!configure_params) {
        return make_unexpected(configure_params.status());
    }

    auto network_groups = vdevice.configure(hef.value(), configure_params.value());
    if (!network_groups) {
        return make_unexpected(network_groups.status());
    }

    if (1 != network_groups->size()) {
        std::cerr << "Invalid amount of network groups" << std::endl;
        return make_unexpected(HAILO_INTERNAL_FAILURE);
    }

    return std::move(network_groups->at(0));
}

// [변경] 입력 스레드: 미리 전처리된 이미지를 계속해서 Write 합니다.
void write_all(InputVStream &input,
               std::vector<uint8_t> &data,
               hailo_status &status,
               size_t thread_id)     // 추가
{
    for (size_t i = 0; i < FRAMES_COUNT; i++) {
        std::cout << "[Input Thread " << thread_id << "] frame=" << i << std::endl;

        status = input.write(MemoryView(data.data(), data.size()));
        if (HAILO_SUCCESS != status) {
            std::cerr << "[Input Thread " << thread_id << "] Failed to write" << std::endl;
            return;
        }
    }
}

// [변경] 출력 스레드: 결과를 읽고 라벨을 출력합니다.
void read_all(OutputVStream &output,
              const std::vector<std::string> &labels,
              hailo_status &status,
              size_t thread_id)     // 추가
{
    std::vector<uint8_t> data(output.get_frame_size());

    for (size_t i = 0; i < FRAMES_COUNT; i++) {
        std::cout << "[Output Thread " << thread_id << "] frame=" << i << std::endl;

        status = output.read(MemoryView(data.data(), data.size()));
        if (HAILO_SUCCESS != status) {
            std::cerr << "[Output Thread " << thread_id << "] Failed to read" << std::endl;
            return;
        }
    }
}

hailo_status infer(std::vector<InputVStream> &input_streams, 
                   std::vector<OutputVStream> &output_streams, 
                   ThreadData &thread_data)
{
    hailo_status status = HAILO_SUCCESS;
    hailo_status input_status[MAX_LAYER_EDGES] = {HAILO_UNINITIALIZED};
    hailo_status output_status[MAX_LAYER_EDGES] = {HAILO_UNINITIALIZED};
    std::unique_ptr<std::thread> input_threads[MAX_LAYER_EDGES];
    std::unique_ptr<std::thread> output_threads[MAX_LAYER_EDGES];
    size_t input_thread_index = 0;
    size_t output_thread_index = 0;

    // Create Read Threads (Output)
    for (output_thread_index = 0; output_thread_index < output_streams.size(); output_thread_index++) {
        output_threads[output_thread_index] = std::make_unique<std::thread>(
            read_all,
            std::ref(output_streams[output_thread_index]),
            std::cref(thread_data.labels),
            std::ref(output_status[output_thread_index]),
            output_thread_index    // thread ID 전달
        );
    }

    // Create Write Threads (Input)
    for (input_thread_index = 0; input_thread_index < input_streams.size(); input_thread_index++) {
        input_threads[input_thread_index] = std::make_unique<std::thread>(
            write_all,
            std::ref(input_streams[input_thread_index]),
            std::ref(thread_data.input_data),
            std::ref(input_status[input_thread_index]),
            input_thread_index     // thread ID 전달
        );
    }

    // Join Threads (무한 루프이므로 여기서 블로킹됩니다)
    for (size_t i = 0; i < input_thread_index; i++) {
        if (input_threads[i]->joinable()) {
            input_threads[i]->join();
        } 
    }
    
    for (size_t i = 0; i < output_thread_index; i++) {
        if (output_threads[i]->joinable()) {
            output_threads[i]->join();
        }
    }

    return status;
}

Expected<std::unique_ptr<VDevice>> create_vdevice()
{
    hailo_vdevice_params_t params;
    auto status = hailo_init_vdevice_params(&params);
    if (HAILO_SUCCESS != status) {
        std::cerr << "Failed init vdevice_params, status = " << status << std::endl;
        return make_unexpected(status);
    }
    
    params.device_count = DEVICE_COUNT;
    params.multi_process_service = true; // 멀티 프로세스 활성화
    params.group_id = "SHARED";

    return VDevice::create(params);
}

int main(int argc, char **argv)
{
    // [변경] 인자 확장: HEF, 이미지 경로, 라벨 파일
    if (4 > argc) {
        std::cerr << "Usage: ./multi_process <hef_path> <image_path> <labels_json_path>" << std::endl;
        return HAILO_INVALID_ARGUMENT;
    }
    std::string hef_path = argv[1];
    std::string image_path = argv[2];
    std::string labels_path = argv[3];

    // 1. VDevice 생성
    auto vdevice = create_vdevice();
    if (!vdevice) {
        std::cerr << "Failed create vdevice: " << vdevice.status() << std::endl;
        return vdevice.status();
    }

    // 2. 네트워크 그룹 설정
    auto network_group = configure_network_group(hef_path, *vdevice.value());
    if (!network_group) {
        std::cerr << "Failed to configure network group" << std::endl;
        return network_group.status();
    }

    // 3. VStream 생성
    auto vstreams = VStreamsBuilder::create_vstreams(*network_group.value(), {}, FORMAT_TYPE);
    if (!vstreams) {
        std::cerr << "Failed creating vstreams: " << vstreams.status() << std::endl;
        return vstreams.status();
    }

    // 4. 데이터 준비 (이미지 전처리 & 라벨 로드)
    ThreadData thread_data;

    // 4-1. 라벨 로드
    try {
        thread_data.labels = util::load_labels_jsoncpp(labels_path);
    } catch (const std::exception &e) {
        std::cerr << "Error loading labels: " << e.what() << std::endl;
        return HAILO_INVALID_ARGUMENT;
    }

    // 4-2. 입력 스트림 정보에서 Quantization 정보 가져오기
    if (vstreams->first.empty()) {
        std::cerr << "No input vstreams found" << std::endl;
        return HAILO_INTERNAL_FAILURE;
    }
    auto &input_vstream = vstreams->first[0];
    auto input_info = input_vstream.get_info();
    float qp_scale = input_info.quant_info.qp_scale;
    float qp_zp    = input_info.quant_info.qp_zp;

    // 4-3. 이미지 로드 및 전처리 (inference_driver.cpp 참조)
    cv::Mat img = cv::imread(image_path, cv::IMREAD_COLOR);
    if (img.empty()) {
        std::cerr << "Failed to load image: " << image_path << std::endl;
        return HAILO_INVALID_ARGUMENT;
    }

    // util 함수를 사용하여 ResNet 형식으로 전처리
    cv::Mat preprocessed = util::preprocess_image_resnet_uint8(img, qp_scale, qp_zp);
    
    // 데이터 복사
    thread_data.input_data.resize(input_vstream.get_frame_size());
    if (thread_data.input_data.size() != preprocessed.total() * preprocessed.channels()) {
        std::cerr << "Size mismatch: Buffer " << thread_data.input_data.size() 
                  << " vs Image " << preprocessed.total() * preprocessed.channels() << std::endl;
        return HAILO_INVALID_OPERATION;
    }
    std::memcpy(thread_data.input_data.data(), preprocessed.data, thread_data.input_data.size());

    std::cout << "Starting Infinite Inference on " << hef_path << "..." << std::endl;

    // 5. 추론 시작 (무한 루프)
    auto status = infer(vstreams->first, vstreams->second, thread_data);
    if (HAILO_SUCCESS != status) {
        std::cerr << "Inference failed with status " << status << std::endl;
        return status;
    }

    return HAILO_SUCCESS;
}