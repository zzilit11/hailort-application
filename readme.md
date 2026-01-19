
**Build**
To build the library with Multi-Process Service enabled, run:

```bash 
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DHAILO_BUILD_SERVICE=1 && sudo cmake --build build --config Release --target install 
```

**Copy the env file**

```bash
sudo mkdir -p /etc/default
sudo cp /usr/local/etc/default/hailort_service /etc/default/hailort_service
```

example
```bash
cat /etc/default/hailort_service 
# This file contains HailoRT's configurable environment variables for HailoRT Linux Service.
# The environment variables are set to their default values.
# To change an environment variable's value, follow the steps:
# 1. Change the value of the selected environemt variable in this file
# 2. Reload systemd unit files by running: `sudo systemctl daemon-reload`
# 3. Copy this file to /etc/default/hailort_service
# 4. Enable and start service by running: `sudo systemctl enable --now hailort.service`

[Service]
HAILORT_LOGGER_PATH="/home/taespberry/WORKSPACE/log_service"
HAILO_MONITOR=1
HAILO_TRACE=scheduler
HAILO_TRACE_TIME_IN_SECONDS_BOUNDED_DUMP=0
HAILO_TRACE_SIZE_IN_KB_BOUNDED_DUMP=0
HAILO_TRACE_PATH="/home/taespberry/WORKSPACE/traces"
```

**Enable Service**
Enable and start the multi-process service with:

```bash 
sudo systemctl enable --now hailort.service
```
If the service does not start properly, restart it:

```bash 
sudo systemctl restart hailort.service
```

**Configure the Hailo Service**
(Optional) Edit the service configuration file if needed:

```bash 
cat /etc/default/hailort_service
sudo nano /etc/default/hailort_service
```

Apply configuration changes:

```bash 
sudo systemctl daemon-reload
```


