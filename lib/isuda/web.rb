require 'digest/sha1'
require 'json'
require 'net/http'
require 'uri'

require 'erubis'
require 'mysql2'
require 'mysql2-cs-bind'
require 'rack/utils'
require 'sinatra/base'
require 'tilt/erubis'

module Isuda
  class Web < ::Sinatra::Base

    enable :protection
    enable :sessions

    set :erb, escape_html: true
    set :public_folder, File.expand_path('../../../../public', __FILE__)
    set :db_user, ENV['ISUDA_DB_USER'] || 'root'
    set :db_password, ENV['ISUDA_DB_PASSWORD'] || ''
    set :dsn, ENV['ISUDA_DSN'] || 'dbi:mysql:db=isuda'
    set :session_secret, 'tonymoris'
    set :isupam_origin, ENV['ISUPAM_ORIGIN'] || 'http://localhost:5050'
    set :isutar_origin, ENV['ISUTAR_ORIGIN'] || 'http://localhost:5001'
    set :isuda_origin, ENV['ISUDA_ORIGIN'] || 'http://localhost:5000'

    configure :development do
      require 'sinatra/reloader'
      set :public_folder, File.expand_path('../../../public', __FILE__)
      register Sinatra::Reloader
    end

    set(:set_name) do |value|
      condition {
        user_id = session[:user_id]
        if user_id
          user = db.xquery(%| select name from user where id = ? |, user_id).first
          @user_id = user_id
          @user_name = user[:name]
          halt(403) unless @user_name
        end
      }
    end

    set(:authenticate) do |value|
      condition {
        halt(403) unless @user_id
      }
    end

    helpers do
      require_relative 'memoizable'
      include Memoizable

      def db
        Thread.current[:db] ||=
          begin
            _, _, attrs_part = settings.dsn.split(':', 3)
            attrs = Hash[attrs_part.split(';').map {|part| part.split('=', 2) }]
            mysql = Mysql2::Client.new(
              username: settings.db_user,
              password: settings.db_password,
              database: attrs['db'],
              encoding: 'utf8mb4',
              init_command: %|SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY'|,
            )
            mysql.query_options.update(symbolize_keys: true)
            mysql
          end
      end

      def register(name, pw)
        chars = [*'A'..'~']
        salt = 1.upto(20).map { chars.sample }.join('')
        salted_password = encode_with_salt(password: pw, salt: salt)
        db.xquery(%|
          INSERT INTO user (name, salt, password, created_at)
          VALUES (?, ?, ?, NOW())
        |, name, salt, salted_password)
        db.last_id
      end

      def encode_with_salt(password: , salt: )
        Digest::SHA1.hexdigest(salt + password)
      end

      def is_spam_content(content)
        isupam_uri = URI(settings.isupam_origin)
        res = Net::HTTP.post_form(isupam_uri, 'content' => content)
        validation = JSON.parse(res.body)
        validation['valid']
        ! validation['valid']
      end

      def cached_patterns
        redis_get('patterns') || refresh_patterns
      end

      def refresh_patterns
        Regexp.escape(db.xquery(%| SELECT GROUP_CONCAT(e.keyword) AS keywords FROM entry AS e |).first[:keywords]).gsub(',', '|').tap do |keywords|
          redis_set('patterns', keywords)
        end
      end

      def htmlify(content)
        kw2hash = {}
        hashed_content = content.gsub(/(#{cached_patterns})/) {|m|
          matched_keyword = $1
          "isuda_#{Digest::SHA1.hexdigest(matched_keyword)}".tap do |hash|
            kw2hash[matched_keyword] = hash
          end
        }
        escaped_content = Rack::Utils.escape_html(hashed_content)
        kw2hash.each do |(keyword, hash)|
          escaped_content.gsub!(hash, keyword_to_hash(keyword))
        end
        escaped_content.gsub(/\n/, "<br />\n")
      end
      memoize :htmlify

      def escaped_content(hashed_content)
        Rack::Utils.escape_html(hashed_content)
      end
      memoize :escaped_content

      def keyword_to_hash(keyword)
        keyword_url = url("/keyword/#{Rack::Utils.escape_path(keyword)}")
        '<a href="%s">%s</a>' % [keyword_url, Rack::Utils.escape_html(keyword)]
      end
      memoize :keyword_to_hash

      def uri_escape(str)
        Rack::Utils.escape_path(str)
      end

      # starローカル化
      def load_stars(keyword)
        keyword = keyword || ''
        db.xquery(%| select * from star where keyword = ? |, keyword).to_a
      end

      def redirect_found(path)
        redirect(path, 302)
      end

      def cached_total_entries
        redis_get('total_entries') || refresh_total_entries
      end

      def refresh_total_entries
        db.xquery(%| SELECT COUNT(*) AS count FROM entry |).first[:count].to_i.tap do |value|
          redis_set('total_entries', value)
        end
      end
    end

    get '/initialize' do
      db.xquery(%| DELETE FROM entry WHERE id > 7101 |)
      db.xquery('TRUNCATE star')

      content_type :json
      JSON.generate(result: 'ok')
    end

    # starローカル化
    post '/stars' do
      keyword = params[:keyword]

      isuda_keyword_url = URI(settings.isuda_origin)
      isuda_keyword_url.path = '/keyword/%s' % [Rack::Utils.escape_path(keyword)]
      res = Net::HTTP.get_response(isuda_keyword_url)
      halt(404) unless Net::HTTPSuccess === res

      user_name = params[:user]
      db.xquery(%|
        INSERT INTO star (keyword, user_name, created_at)
        VALUES (?, ?, NOW())
      |, keyword, user_name)

      content_type :json
      JSON.generate(result: 'ok')
    end

    get '/', set_name: true do
      per_page = 10
      page = (params[:page] || 1).to_i

      entries = db.xquery(%|
        SELECT * FROM entry
        ORDER BY updated_at DESC
        LIMIT #{per_page}
        OFFSET #{per_page * (page - 1)}
      |)
      entries.each do |entry|
        entry[:html] = htmlify(entry[:description])
        entry[:stars] = load_stars(entry[:keyword])
      end

      #total_entries = db.xquery(%| SELECT count(*) AS total_entries FROM entry |).first[:total_entries].to_i
      total_entries = cached_total_entries

      last_page = (total_entries.to_f / per_page.to_f).ceil
      from = [1, page - 5].max
      to = [last_page, page + 5].min
      pages = [*from..to]

      locals = {
        entries: entries,
        page: page,
        pages: pages,
        last_page: last_page,
      }
      erb :index, locals: locals
    end

    get '/robots.txt' do
      halt(404)
    end

    get '/register', set_name: true do
      erb :register
    end

    post '/register' do
      name = params[:name] || ''
      pw   = params[:password] || ''
      halt(400) if (name == '') || (pw == '')

      user_id = register(name, pw)
      session[:user_id] = user_id

      redirect_found '/'
    end

    get '/login', set_name: true do
      locals = {
        action: 'login',
      }
      erb :authenticate, locals: locals
    end

    post '/login' do
      name = params[:name]
      user = db.xquery(%| select * from user where name = ? |, name).first
      halt(403) unless user
      halt(403) unless user[:password] == encode_with_salt(password: params[:password], salt: user[:salt])

      session[:user_id] = user[:id]

      redirect_found '/'
    end

    get '/logout' do
      session[:user_id] = nil
      redirect_found '/'
    end

    post '/keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] || ''
      halt(400) if keyword == ''
      description = params[:description]
      halt(400) if is_spam_content(description) || is_spam_content(keyword)

      bound = [@user_id, keyword, description] * 2
      db.xquery(%|
        INSERT INTO entry (author_id, keyword, description, created_at, updated_at)
        VALUES (?, ?, ?, NOW(), NOW())
        ON DUPLICATE KEY UPDATE
        author_id = ?, keyword = ?, description = ?, updated_at = NOW()
      |, *bound)

      # パターン更新
      refresh_patterns

      # エントリーのカウント更新
      refresh_total_entries

      redirect_found '/'
    end

    get '/keyword/:keyword', set_name: true do
      keyword = params[:keyword] or halt(400)

      entry = db.xquery(%| select * from entry where keyword = ? |, keyword).first or halt(404)
      entry[:stars] = load_stars(entry[:keyword])
      entry[:html] = htmlify(entry[:description])

      locals = {
        entry: entry,
      }
      erb :keyword, locals: locals
    end

    post '/keyword/:keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] or halt(400)
      is_delete = params[:delete] or halt(400)

      unless db.xquery(%| SELECT * FROM entry WHERE keyword = ? |, keyword).first
        halt(404)
      end

      db.xquery(%| DELETE FROM entry WHERE keyword = ? |, keyword)

      # エントリーのカウント更新
      refresh_total_entries

      redirect_found '/'
    end
  end
end
