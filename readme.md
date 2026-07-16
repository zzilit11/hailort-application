# HailoRT Application

## Build

Build the single inference target:

```bash
./build_inference.sh
```

Build the multi-process target:

```bash
./build_multi_process.sh
```

Both scripts use CMake for configure and build.

## Run Single Inference

```bash
./run_inference.sh
```

This runs `build/inference_driver` with the model, image directory, and labels configured in the script.

## Run Multi-Process Inference

```bash
./run_inference_multi.sh
```

This runs `build/multi_process` with the model, image, labels, and scheduler parameters configured in the script.

## Notes

This project no longer uses `hailort.service`. The old service-based scripts and `systemctl` flow were removed.
