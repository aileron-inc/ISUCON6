worker_processes 5
timeout 120

shared_path = File.expand_path('shared')
listen File.expand_path('tmp/isutar.sock', shared_path)

stdout_path File.expand_path('log/isutar.log')
stderr_path File.expand_path('log/isutar.log')

preload_app true
