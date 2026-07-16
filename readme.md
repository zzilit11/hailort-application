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

전체 script를 `sudo`로 실행하지 않는다. Worker와 log directory는 일반 사용자
소유로 유지하고, script가 foreground에서 trace helper를 호출할 때 sudo password를
한 번 입력한다. Helper는 `vctx_trace` sysfs write와 제한된 `dmesg` read만
승격한다. `/dev/hailo*` open 자체가 거부된다면 root로 worker를 실행하지 말고
device node의 udev/group 권한을 수정해야 한다.

script는 다음 순서로 동작한다.

1. KMD `vctx_trace`를 활성화하고 `dmesg` 수집을 시작한다.
2. 동일한 `build/multi_process` 실행 파일을 worker A와 B로 각각 실행한다.
3. 각 worker가 독립적으로 VDevice, HEF, network group, VStream을 구성한다.
4. 두 worker의 `ready.A`, `ready.B`를 확인한 후 공통 start barrier를 해제한다.
5. 두 process의 종료 코드, 추론 시간 중첩 및 KMD VCTX 개수를 검사한다.

KMD dispatch는 경쟁 process가 있을 때 현재 VCTX를 기본 `50ms` 또는 commit
`64개` 중 먼저 도달한 경계까지 유지한다. 같은 VCTX의 transfer는 채널 queue의
다른 VCTX 항목을 건너뛸 수 있지만, 같은 VCTX 내부 FIFO는 유지한다. Quantum이
닫히면 신규 transfer admission을 중단하고 이미 commit된 transfer가 모두 끝난
후에만 firmware VCTX를 전환한다.

두 module parameter는 시험 전에 조정할 수 있다. 둘 다 `0`이면 기존의 즉시 전환
정책으로 돌아간다.

```bash
echo 50 | sudo tee /sys/module/hailo_pci/parameters/vctx_dispatch_quantum_ms
echo 64 | sudo tee /sys/module/hailo_pci/parameters/vctx_dispatch_quantum_transfers
```

Matrix 시험도 일반 사용자로 실행한다.

```bash
./run_vctx_experiment_matrix.sh
```

호출 관계와 권한 경계는 다음과 같다.

```text
run_vctx_experiment_matrix.sh        normal user, sudo 사전 인증 1회
  +-- run_inference_multi.sh         normal user
  |     +-- hailo_vctx_trace.sh      sysfs/dmesg 명령만 제한적 sudo
  |     +-- multi_process A/B        normal user
  +-- run_inference_single_control.sh
        +-- hailo_vctx_trace.sh      sysfs/dmesg 명령만 제한적 sudo
        +-- multi_process            normal user
```

Trace helper를 단독으로 사용할 때는 아래처럼 실행한다.

```bash
# Terminal에서 인증 후 바로 trace
../hailort-drivers/linux/pcie/tools/hailo_vctx_trace.sh

# Orchestrator에서 foreground 인증과 background follow를 분리
../hailort-drivers/linux/pcie/tools/hailo_vctx_trace.sh --authorize
../hailort-drivers/linux/pcie/tools/hailo_vctx_trace.sh --follow
```

`--follow`는 `--authorize`와 같은 login session에서 실행한다. Runner는 trace
process를 별도 `setsid` session으로 이동하지 않으며, helper가 dmesg producer와
grep consumer를 직접 종료하고 `vctx_trace` 값을 복원한다. Trace 시작이 실패하면
runner가 `dmesg-vctx.log` 마지막 20줄을 terminal에도 출력한다.

최신 quantum KMD/runner가 반영됐다면 각 case의 configuration 출력에 다음 두 줄이
나타난다. 줄 자체가 없으면 target board의 application script가 이전 버전이고,
값이 `unavailable`이면 최신 `hailo_pci` module이 load되지 않은 상태다.

```text
vctx_dispatch_quantum_ms=50
vctx_dispatch_quantum_transfers=64
```

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
- output VStream이 정상적으로 decode되고 모든 frame에서 Top1 class가
  계산되었다.
- softmax output의 범위와 합이 유효하다. Native `UINT8` output이
  `FLOAT32`로 변환된 경우 `1.0/0.0` one-hot score도 유효한 분류
  결과로 인정한다.
- 두 process가 HailoRT inference 호출 안에 머문 시간이 서로 중첩된다.
- dmesg에서 서로 다른 `vctx=<id>`가 2개 이상 관측된다.
- trace가 활성화된 경우 `CHANNEL_CURSOR_REBASE physical_idle_failed=1` 및
  `TRANSFER_STALL_WARN`이 없다.

`configuration.txt`에는 실제 module의 quantum parameter가, `summary.txt`에는
`device_switches`, `quantum_begins`, `quantum_requests`가 기록된다. dmesg의
`VCTX_QUANTUM_REQUEST`는 경쟁자가 quantum을 닫은 시점이고,
`VCTX_QUANTUM_BEGIN`은 drain과 firmware 전환이 끝나 새 owner가 시작한 시점이다.

`transport_result`는 모든 frame의 input/output 전송 완료, process 실행 중첩,
VCTX/cursor/stall 조건을 나타낸다. `classification_result`는 output decode,
frame 완료 및 Top1 계산 성공 여부를 나타낸다. `score_result`는 기존 log
분석과의 호환을 위한 `classification_result`의 alias이다. Label이 정답인지는
정답 annotation을 입력받지 않으므로 자동 판정하지 않고, 실제 Top1 label을 log에
출력한다.

## VCTX HTML timeline

`tools/vctx_timeline.py`는 matrix 전체, 개별 run directory 또는
`dmesg-vctx.log` 하나를 입력받아 외부 package가 필요 없는 standalone HTML을
생성한다.

```bash
python3 tools/vctx_timeline.py \
    logs/vctx-matrix-20260716-185733-50746
```

기본 출력은 입력 directory의 `vctx-timeline.html`이다. 출력 위치를 지정할 수도
있다.

```bash
python3 tools/vctx_timeline.py RUN_DIRECTORY \
    --output /tmp/vctx-timeline.html
```

HTML에는 다음 정보가 포함된다.

- VCTX별 device ownership과 firmware switch
- quantum request/begin 및 quantum별 누적 commit 수
- engine/channel별 transfer commit-to-complete 구간
- logical/physical descriptor 위치와 ring-wrap 강조
- cursor rebase, stall, reject, abort event
- worker transport/classification 결과와 실행 시간
- 시간 범위 zoom/pan, hover detail 및 event 검색/filter

기본적으로 반복량이 많은 `WAIT_EVENT`, `WAIT_DELIVER`, `WORKER_DRAIN`은 제외한다.
이 event까지 포함하려면 `--include-wait-events`를 사용한다.

worker log의 `inference-result-summary`에는 user/native output format, 첫/마지막
frame의 score 합·최솟값·최댓값·양수 class 수,
`classification_result=PASS|FAIL` 및 `score_validation=PASS|FAIL`이 기록된다.
softmax Top1이 `1.000000000`이고 나머지가 0인 frame은
`one_hot_score_frames`로 계수하지만 정상 추론으로 인정한다. 즉 score 분포
진단은 유지하면서 Top1 분류 성공 판정과 분리한다.

시간 중첩은 두 process가 동시에 실행 중이었다는 userspace 증거이며, 실제 transfer
전환은 `dmesg-vctx.log`의 `vctx-trace`와 `vctx-fw` 순서를 함께 확인해야 한다.

수정된 `hailo_pci` module이 아직 `vctx_trace` parameter를 제공하지 않거나
trace 없이 추론만 실행하려면 trace를 끌 수 있다. 이 경우 sudo를 전혀
사용하지 않으며 VCTX 개수 조건은 검사하지 않는다.

```bash
ENABLE_VCTX_TRACE=0 ./run_inference_multi.sh

# Matrix 전체에서 trace 비활성화
ENABLE_VCTX_TRACE=0 ./run_vctx_experiment_matrix.sh
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
