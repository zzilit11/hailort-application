# HailoRT Application

## Build

```bash
./scripts/build/build_multi_process.sh
./scripts/build/build_inference.sh
```

빌드 경로를 변경하려면:

```bash
BUILD_DIR=/tmp/hailort-build ./scripts/build/build_multi_process.sh
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
./scripts/experiment/run_vctx_experiment_matrix.sh
```

장시간 case를 생략하려면:

```bash
RUN_LONG_MULTI=0 ./scripts/experiment/run_vctx_experiment_matrix.sh
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
./scripts/run/run_inference_multi.sh
```

Worker별 scheduler 설정:

```bash
PRIORITY_A=16 PRIORITY_B=8 \
BATCH_SIZE_A=10 BATCH_SIZE_B=10 \
SCHEDULER_THRESHOLD_A=3 SCHEDULER_THRESHOLD_B=3 \
./scripts/run/run_inference_multi.sh
```

Trace 없이 실행:

```bash
ENABLE_VCTX_TRACE=0 ./scripts/run/run_inference_multi.sh
ENABLE_VCTX_TRACE=0 ./scripts/experiment/run_vctx_experiment_matrix.sh
```

## Single inference

일반 inference:

```bash
./scripts/run/run_inference.sh
```

Single-process control:

```bash
./scripts/run/run_inference_single_control.sh
```

환경 변수로 경로를 변경할 수 있다:

```bash
MODEL=/models/model.hef \
IMAGE=/images/image.png \
CLASS_LABELS=/labels/imagenet_labels.json \
FRAME_COUNT=200 \
./scripts/run/run_inference_single_control.sh
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

실행 결과는 `logs/` 아래에 저장된다.
