worker_processes 5
preload_app true
timeout 120

stdout_path File.expand_path('log/isutar.log')
stderr_path File.expand_path('log/isutar_error.log')
