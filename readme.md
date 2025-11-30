
Build the library with Multi-Process Service enabled

"""
cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release -DHAILO_BUILD_SERVICE=1 && sudo cmake --build build --config release --target install
"""