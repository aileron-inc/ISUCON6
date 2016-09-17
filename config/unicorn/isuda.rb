worker_processes 10
timeout 5

listen File.expand_path('tmp/isuda.sock')

stdout_path File.expand_path('log/isuda.log')
stderr_path File.expand_path('log/isuda.log')

preload_app true
