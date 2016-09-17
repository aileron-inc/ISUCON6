worker_processes 20
timeout 5

listen File.expand_path('tmp/isuda.sock')

preload_app true
