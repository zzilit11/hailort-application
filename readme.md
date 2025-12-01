
**Build**
To build the library with Multi-Process Service enabled, run:

```bash 
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DHAILO_BUILD_SERVICE=1 && sudo cmake --build build --config Release --target install 
```

**Enable Service**
After installation, enable and start the multi-process service with:

```bash 
sudo systemctl enable --now hailort.service
```
If the service does not start properly, restart it:

```bash 
sudo systemctl restart hailort.service
```
