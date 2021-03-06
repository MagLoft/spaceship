module Spaceship
  class TunesClient < Spaceship::Client

    #####################################################
    # @!group Init and Login
    #####################################################

    def self.hostname
      "https://itunesconnect.apple.com/WebObjects/iTunesConnect.woa/"
    end

    # Fetches the latest login URL from iTunes Connect
    def login_url
      cache_path = "/tmp/spaceship_itc_login_url.txt"
      begin
        cached = File.read(cache_path) 
      rescue Errno::ENOENT
      end
      return cached if cached

      host = "https://itunesconnect.apple.com"
      begin
        url = host + request(:get, self.class.hostname).body.match(/action="(\/WebObjects\/iTunesConnect.woa\/wo\/.*)"/)[1]
        raise "" unless url.length > 0

        File.write(cache_path, url) # TODO
        return url
      rescue => ex
        puts ex
        raise "Could not fetch the login URL from iTunes Connect, the server might be down"
      end
    end

    def send_login_request(user, password)
      response = request(:post, login_url, {
        theAccountName: user,
        theAccountPW: password
      })

      if response['Set-Cookie'] =~ /myacinfo=(\w+);/
        # To use the session properly we'll need the following cookies:
        #  - myacinfo
        #  - woinst
        #  - wosid

        begin
          cooks = response['Set-Cookie']

          to_use = [
            "myacinfo=" + cooks.match(/myacinfo=(\w+)/)[1],
            "woinst=" + cooks.match(/woinst=(\w+)/)[1],
            "wosid=" + cooks.match(/wosid=(\w+)/)[1]
          ]

          @cookie = to_use.join(';')
        rescue => ex
          # User Credentials are wrong
          raise InvalidUserCredentialsError.new(response)
        end
        
        return @client
      else
        # User Credentials are wrong
        raise InvalidUserCredentialsError.new(response)
      end
    end

    def handle_itc_response(data)
      return unless data
      return unless data.kind_of?Hash
 
      if data.fetch('sectionErrorKeys', []).count == 0 and
        data.fetch('sectionInfoKeys', []).count == 0 and 
        data.fetch('sectionWarningKeys', []).count == 0
        
        logger.debug("Request was successful")
      end

      def handle_response_hash(hash)
        errors = []
        if hash.kind_of?Hash
          hash.each do |key, value|
            errors = errors + handle_response_hash(value)

            if key == 'errorKeys' and value.kind_of?Array and value.count > 0
              errors = errors + value
            end
          end
        elsif hash.kind_of?Array
          hash.each do |value|
            errors = errors + handle_response_hash(value)
          end
        else
          # We don't care about simple values
        end
        return errors
      end

      errors = handle_response_hash(data)
      errors = errors + data.fetch('sectionErrorKeys') if data['sectionErrorKeys']

      # Sometimes there is a different kind of error in the JSON response
      different_error = data.fetch('messages', {}).fetch('error', nil)
      errors << different_error if different_error

      raise errors.join(' ') if errors.count > 0 # they are separated by `.` by default

      puts data['sectionInfoKeys'] if data['sectionInfoKeys']
      puts data['sectionWarningKeys'] if data['sectionWarningKeys']

      return data
    end


    #####################################################
    # @!group Applications
    #####################################################

    def applications
      r = request(:get, 'ra/apps/manageyourapps/summary')
      parse_response(r, 'data')['summaries']
    end

    # Creates a new application on iTunes Connect
    # @param name (String): The name of your app as it will appear on the App Store. 
    #   This can't be longer than 255 characters.
    # @param primary_language (String): If localized app information isn't available in an 
    #   App Store territory, the information from your primary language will be used instead.
    # @param version (String): The version number is shown on the App Store and should 
    #   match the one you used in Xcode.
    # @param sku (String): A unique ID for your app that is not visible on the App Store.
    # @param bundle_id (String): The bundle ID must match the one you used in Xcode. It 
    #   can't be changed after you submit your first build.
    def create_application!(name: nil, primary_language: nil, version: nil, sku: nil, bundle_id: nil, bundle_id_suffix: nil)
      # First, we need to fetch the data from Apple, which we then modify with the user's values
      r = request(:get, 'ra/apps/create/?appType=ios')
      data = parse_response(r, 'data')

      # Now fill in the values we have
      data['versionString']['value'] = version
      data['newApp']['name']['value'] = name
      data['newApp']['bundleId']['value'] = bundle_id
      data['newApp']['primaryLanguage']['value'] = primary_language || 'English_CA'
      data['newApp']['vendorId']['value'] = sku
      data['newApp']['bundleIdSuffix']['value'] = bundle_id_suffix

      # Now send back the modified hash
      r = request(:post) do |req|
        req.url 'ra/apps/create/?appType=ios'
        req.body = data.to_json
        req.headers['Content-Type'] = 'application/json'
      end
        
      data = parse_response(r, 'data')
      handle_itc_response(data)
    end

    def create_version!(app_id, version_number)
      r = request(:post) do |req|
        req.url "ra/apps/version/create/#{app_id}"
        req.body = { version: version_number.to_s }.to_json
        req.headers['Content-Type'] = 'application/json'
      end

      parse_response(r, 'data')
    end

    def get_resolution_center(app_id)
      r = request(:get, "ra/apps/#{app_id}/resolutionCenter?v=latest")
      data = parse_response(r, 'data')
    end

    #####################################################
    # @!group AppVersions
    #####################################################

    def app_version(app_id, is_live)
      raise "app_id is required" unless app_id

      v_text = (is_live ? 'live' : nil)

      r = request(:get, "ra/apps/version/#{app_id}", {v: v_text})
      parse_response(r, 'data')
    end

    def update_app_version!(app_id, is_live, data)
      raise "app_id is required" unless app_id

      v_text = (is_live ? 'live' : nil)

      r = request(:post) do |req|
        req.url "ra/apps/version/save/#{app_id}?v=#{v_text}"
        req.body = data.to_json
        req.headers['Content-Type'] = 'application/json'
      end
      
      handle_itc_response(r.body['data'])
    end

    #####################################################
    # @!group Build Trains
    #####################################################

    def build_trains(app_id)
      raise "app_id is required" unless app_id

      r = request(:get, "ra/apps/#{app_id}/trains/")
      data = parse_response(r, 'data')
    end

    def update_build_trains!(app_id, data)
      raise "app_id is required" unless app_id

      r = request(:post) do |req|
        req.url "ra/apps/#{app_id}/trains/"
        req.body = data.to_json
        req.headers['Content-Type'] = 'application/json'
      end

      handle_itc_response(r.body['data'])
    end
    
    #####################################################
    # @!group Submit for Review
    #####################################################
    
    def send_app_submission(app_id, data, stage)
      raise "app_id is required" unless app_id

      r = request(:post) do |req|
        req.url "ra/apps/#{app_id}/version/submit/#{stage}"
        req.body = data.to_json
        req.headers['Content-Type'] = 'application/json'
      end
      
      handle_itc_response(r.body['data'])
      parse_response(r, 'data')
    end

  end
end