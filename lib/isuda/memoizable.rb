module Memoizable
  require 'redis'
  redis = Redis.new(host: 'localhost', port: 6379, db: 15)

  define_method(:redis_get) { |name| redis.get(name) }
  define_method(:redis_set) { |name, value| redis.set(name, value) }

  define_singleton_method(:included) do |klass|
    klass.define_singleton_method(:memoize) do |name|
      original = "__unmemoized_#{name}__"

      ([Class, Module].include?(self.class) ? self : self.class).class_eval do
        alias_method original, name
        private      original
        define_method(name) do |*args|
          key = args.hash
          value = redis.get(key)
          return value if value
          value = send(original, *args)
          redis.set(key, value)
          value
        end
        define_method("#{name}_renew") do |*args|
          key = args.hash
          value = send(original, *args)
          redis.set(key, value)
          value
        end
      end
    end
  end
end
