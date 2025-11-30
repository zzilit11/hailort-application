
Build the library with Multi-Process Service enabled

```bash 
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DHAILO_BUILD_SERVICE=1 && sudo cmake --build build --config Release --target install 
```