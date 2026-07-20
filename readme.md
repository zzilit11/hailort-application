# HailoRT Application

## Build

```bash
bash ./scripts/build/build_multi_process.sh
bash ./scripts/build/build_inference_driver.sh
```

빌드 경로를 변경하려면:

```bash
BUILD_DIR=/tmp/hailort-build bash ./scripts/build/build_multi_process.sh
```

## VCTX trace

Trace helper는 별도 터미널에서 실행한다. 추론과 matrix는 `sudo` 없이 실행한다.

```bash
# Terminal 1
../hailort-drivers/linux/pcie/tools/hailo_vctx_trace.sh

# 또는 인증과 follow를 분리
../hailort-drivers/linux/pcie/tools/hailo_vctx_trace.sh --authorize
../hailort-drivers/linux/pcie/tools/hailo_vctx_trace.sh --follow
```

선택적 quantum 설정:

```bash
echo 50 | sudo tee /sys/module/hailo_pci/parameters/vctx_dispatch_quantum_ms
echo 64 | sudo tee /sys/module/hailo_pci/parameters/vctx_dispatch_quantum_transfers
```

## Two-process test

```bash
# Terminal 2
bash ./scripts/experiment/run_vctx_matrix_resnet50.sh
```

장시간 case를 생략하려면:

```bash
RUN_LONG_MULTI=0 bash ./scripts/experiment/run_vctx_matrix_resnet50.sh
```

## Custom inference

```bash
MODEL_A=/models/resnet_v1_50.hef \
MODEL_B=/models/resnet_v1_50.hef \
IMAGE_A=/images/_images_1.png \
IMAGE_B=/images/_images_2.png \
CLASS_LABELS_A=/labels/imagenet_labels.json \
CLASS_LABELS_B=/labels/imagenet_labels.json \
FRAME_COUNT=500 \
bash ./scripts/run/run_vctx_two_process_resnet50.sh
```

Worker별 scheduler 설정:

```bash
PRIORITY_A=16 PRIORITY_B=8 \
BATCH_SIZE_A=10 BATCH_SIZE_B=10 \
SCHEDULER_THRESHOLD_A=3 SCHEDULER_THRESHOLD_B=3 \
bash ./scripts/run/run_vctx_two_process_resnet50.sh
```

Trace 없이 실행:

```bash
ENABLE_VCTX_TRACE=0 bash ./scripts/run/run_vctx_two_process_resnet50.sh
ENABLE_VCTX_TRACE=0 bash ./scripts/experiment/run_vctx_matrix_resnet50.sh
```

## Four-process test

모델별 스크립트는 A-D worker 모두에 해당 모델을 기본값으로 사용한다.
`MODEL_A`부터 `MODEL_D`까지의 환경 변수로 worker별 HEF를 변경할 수 있다.

```bash
# ResNet50
bash ./scripts/experiment/run_vctx_four_process_resnet50.sh

# ViT Base
bash ./scripts/experiment/run_vctx_four_process_vit.sh
```

## Single inference

일반 inference:

```bash
bash ./scripts/run/run_batch_inference_resnet50.sh
```

Single-process control:

```bash
bash ./scripts/run/run_vctx_single_control_resnet50.sh
```

환경 변수로 경로를 변경할 수 있다:

```bash
MODEL=/models/model.hef \
IMAGE=/images/image.png \
CLASS_LABELS=/labels/imagenet_labels.json \
FRAME_COUNT=200 \
bash ./scripts/run/run_vctx_single_control_resnet50.sh
```

## VCTX timeline

```bash
python3 tools/vctx_timeline.py logs/vctx-matrix-<RUN_ID>
```

출력 파일 지정:

```bash
python3 tools/vctx_timeline.py logs/vctx-matrix-<RUN_ID> \
    --output /tmp/vctx-timeline.html
```

timeline은 `QUEUE → ADMIT → COMMIT → COMPLETE/ABORT` transfer lifecycle을 분리해 표시한다.
점선은 admission 대기 구간이며, device owner 막대는 `DEVICE_SWITCH`에서 시작해 해당
VCTX의 firmware `pause`에서 끝난다. quantum request 선은 전환 요청부터 다음
`VCTX_QUANTUM_BEGIN`까지의 drain/전환 대기 시간을 나타낸다.

`logical ring-wrap`과 `physical ring-wrap` 횟수는 descriptor cursor가 원형 ring의
끝을 지나 0으로 돌아간 정상 동작 횟수이며 오류 횟수가 아니다. timeline에서는 정상
logical ring-wrap을 주황색 윤곽선으로, 실제 reject/abort/stall/drop 오류를 빨간색으로
구분한다.

실행 결과는 `logs/` 아래에 저장된다.
