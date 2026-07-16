# HailoRT Application

## Build

Raspberry Pi에서 multi-process worker를 빌드한다.

```bash
./build_multi_process.sh
```

이 target은 `src/multi_process.cpp`와 `src/util.cpp`로 구성된다. 실행 시 HailoRT
service를 사용하지 않고 각 OS process가 직접 Hailo device를 연다.

```text
multi_process_service=0
VDevice group=UNIQUE
scheduler=ROUND_ROBIN (process-local)
```

## Two-process direct-mode test

기본 Raspberry Pi 경로가 현재 환경과 같으면 다음 명령만 실행한다.

```bash
./run_inference_multi.sh
```

script는 다음 순서로 동작한다.

1. KMD `vctx_trace`를 활성화하고 `dmesg` 수집을 시작한다.
2. 동일한 `build/multi_process` 실행 파일을 worker A와 B로 각각 실행한다.
3. 각 worker가 독립적으로 VDevice, HEF, network group, VStream을 구성한다.
4. 두 worker의 `ready.A`, `ready.B`를 확인한 후 공통 start barrier를 해제한다.
5. 두 process의 종료 코드, 추론 시간 중첩 및 KMD VCTX 개수를 검사한다.

기본 시험은 두 process에서 동일한 ResNet50 HEF와 입력 이미지를 각각 200 frame
실행한다. 경로 또는 frame 수는 환경 변수로 변경할 수 있다.

```bash
MODEL_A=/models/resnet_v1_50.hef \
MODEL_B=/models/resnet_v1_50.hef \
IMAGE_A=/images/_images_1.png \
IMAGE_B=/images/_images_2.png \
CLASS_LABELS_A=/labels/imagenet_labels.json \
CLASS_LABELS_B=/labels/imagenet_labels.json \
FRAME_COUNT=500 \
./run_inference_multi.sh
```

서로 다른 scheduler parameter도 process별로 지정할 수 있다.

```bash
PRIORITY_A=16 PRIORITY_B=8 \
BATCH_SIZE_A=10 BATCH_SIZE_B=10 \
SCHEDULER_THRESHOLD_A=3 SCHEDULER_THRESHOLD_B=3 \
./run_inference_multi.sh
```

## Result

각 실행 결과는 아래 형식의 새 디렉터리에 보존된다.

```text
logs/multi-process-YYYYmmdd-HHMMSS-PID/
├── configuration.txt
├── worker-A.log
├── worker-B.log
├── dmesg-vctx.log
├── summary.txt
└── barrier/
```

`summary.txt`의 `result=PASS`는 다음 조건을 모두 만족했다는 의미다.

- worker A와 B의 exit status가 모두 0이다.
- 두 로그에 `inference-complete status=0`이 존재한다.
- output VStream을 `FLOAT32`로 읽었고 softmax score의 범위와 합이 유효하며
  `1.0/0.0`으로 포화된 frame이 없다.
- 두 process가 HailoRT inference 호출 안에 머문 시간이 서로 중첩된다.
- dmesg에서 서로 다른 `vctx=<id>`가 2개 이상 관측된다.
- trace가 활성화된 경우 `CHANNEL_CURSOR_REBASE physical_idle_failed=1` 및
  `TRANSFER_STALL_WARN`이 없다.

`transport_result`는 모든 frame의 input/output 전송 완료, process 실행 중첩,
VCTX/cursor/stall 조건만 나타내며 `score_result`는 추론 score 검증만 나타낸다.
따라서 전송은 끝났지만 score가 포화된 경우
`transport_result=PASS`, `score_result=FAIL`, 최종 `result=FAIL`로 분리된다.

worker log의 `inference-result-summary`에는 user/native output format, 첫/마지막
frame의 score 합·최솟값·최댓값·양수 class 수와 `score_validation=PASS|FAIL`이
기록된다. 기존 실험처럼 softmax Top-1이 정확히 `1.000000000`이고 나머지가
모두 0이면 정상 추론으로 인정하지 않고 worker가 non-zero로 종료한다.

시간 중첩은 두 process가 동시에 실행 중이었다는 userspace 증거이며, 실제 transfer
전환은 `dmesg-vctx.log`의 `vctx-trace`와 `vctx-fw` 순서를 함께 확인해야 한다.

수정된 `hailo_pci` module이 아직 `vctx_trace` parameter를 제공하지 않거나 sudo를
사용하지 않을 때만 trace를 끌 수 있다. 이 경우 VCTX 개수 조건은 검사하지 않는다.

```bash
ENABLE_VCTX_TRACE=0 ./run_inference_multi.sh
```

## Single-worker compatibility

barrier 인자 없이 worker를 직접 실행하면 기존처럼 한 process가 즉시 추론을 시작한다.

```bash
./build/multi_process MODEL.hef IMAGE.png LABELS.json \
    200 10 16 200 3
```

현재 전처리 코드는 ResNet 224x224 단일-input 모델을 대상으로 한다. 다른 입력 크기나
multi-input HEF는 해당 모델에 맞는 전처리 및 input buffer 구성이 추가로 필요하다.

## Single inference target

기존 단일 추론 예제는 다음 명령으로 빌드 및 실행한다.

```bash
./build_inference.sh
./run_inference.sh
```
