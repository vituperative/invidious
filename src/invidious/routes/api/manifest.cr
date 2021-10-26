module Invidious::Routes::API::Manifest
  # /api/manifest/dash/id/:id
  def self.get_dash_video_id(env)
    env.response.headers.add("Access-Control-Allow-Origin", "*")
    env.response.content_type = "application/dash+xml"

    local = env.params.query["local"]?.try &.== "true"
    id = env.params.url["id"]
    region = env.params.query["region"]?

    # Since some implementations create playlists based on resolution regardless of different codecs,
    # we can opt to only add a source to a representation if it has a unique height within that representation
    unique_res = env.params.query["unique_res"]?.try { |q| (q == "true" || q == "1").to_unsafe }

    begin
      video = get_video(id, PG_DB, region: region)
    rescue ex : VideoRedirect
      return env.redirect env.request.resource.gsub(id, ex.video_id)
    rescue ex
      haltf env, status_code: 403
    end

    if dashmpd = video.dash_manifest_url
      manifest = YT_POOL.client &.get(URI.parse(dashmpd).request_target).body

      manifest = manifest.gsub(/<BaseURL>[^<]+<\/BaseURL>/) do |baseurl|
        url = baseurl.lchop("<BaseURL>")
        url = url.rchop("</BaseURL>")

        if local
          uri = URI.parse(url)
          url = "#{uri.request_target}host/#{uri.host}/"
        end

        "<BaseURL>#{url}</BaseURL>"
      end

      return manifest
    end

    adaptive_fmts = video.adaptive_fmts

    if local
      adaptive_fmts.each do |fmt|
        fmt["url"] = JSON::Any.new(URI.parse(fmt["url"].as_s).request_target)
      end
    end

    audio_streams = video.audio_streams
    video_streams = video.video_streams.sort_by { |stream| {stream["width"].as_i, stream["fps"].as_i} }.reverse!

    manifest = XML.build(indent: "  ", encoding: "UTF-8") do |xml|
      xml.element("MPD", "xmlns": "urn:mpeg:dash:schema:mpd:2011",
        "profiles": "urn:mpeg:dash:profile:full:2011", minBufferTime: "PT1.5S", type: "static",
        mediaPresentationDuration: "PT#{video.length_seconds}S") do
        xml.element("Period") do
          i = 0

          {"audio/mp4", "audio/webm"}.each do |mime_type|
            mime_streams = audio_streams.select { |stream| stream["mimeType"].as_s.starts_with? mime_type }
            next if mime_streams.empty?

            xml.element("AdaptationSet", id: i, mimeType: mime_type, startWithSAP: 1, subsegmentAlignment: true) do
              mime_streams.each do |fmt|
                codecs = fmt["mimeType"].as_s.split("codecs=")[1].strip('"')
                bandwidth = fmt["bitrate"].as_i
                itag = fmt["itag"].as_i
                url = fmt["url"].as_s

                xml.element("Representation", id: fmt["itag"], codecs: codecs, bandwidth: bandwidth) do
                  xml.element("AudioChannelConfiguration", schemeIdUri: "urn:mpeg:dash:23003:3:audio_channel_configuration:2011",
                    value: "2")
                  xml.element("BaseURL") { xml.text url }
                  xml.element("SegmentBase", indexRange: "#{fmt["indexRange"]["start"]}-#{fmt["indexRange"]["end"]}") do
                    xml.element("Initialization", range: "#{fmt["initRange"]["start"]}-#{fmt["initRange"]["end"]}")
                  end
                end
              end
            end

            i += 1
          end

          potential_heights = {4320, 2160, 1440, 1080, 720, 480, 360, 240, 144}

          {"video/mp4", "video/webm"}.each do |mime_type|
            mime_streams = video_streams.select { |stream| stream["mimeType"].as_s.starts_with? mime_type }
            next if mime_streams.empty?

            heights = [] of Int32
            xml.element("AdaptationSet", id: i, mimeType: mime_type, startWithSAP: 1, subsegmentAlignment: true, scanType: "progressive") do
              mime_streams.each do |fmt|
                codecs = fmt["mimeType"].as_s.split("codecs=")[1].strip('"')
                bandwidth = fmt["bitrate"].as_i
                itag = fmt["itag"].as_i
                url = fmt["url"].as_s
                width = fmt["width"].as_i
                height = fmt["height"].as_i

                # Resolutions reported by YouTube player (may not accurately reflect source)
                height = potential_heights.min_by { |i| (height - i).abs }
                next if unique_res && heights.includes? height
                heights << height

                xml.element("Representation", id: itag, codecs: codecs, width: width, height: height,
                  startWithSAP: "1", maxPlayoutRate: "1",
                  bandwidth: bandwidth, frameRate: fmt["fps"]) do
                  xml.element("BaseURL") { xml.text url }
                  xml.element("SegmentBase", indexRange: "#{fmt["indexRange"]["start"]}-#{fmt["indexRange"]["end"]}") do
                    xml.element("Initialization", range: "#{fmt["initRange"]["start"]}-#{fmt["initRange"]["end"]}")
                  end
                end
              end
            end

            i += 1
          end
        end
      end
    end

    return manifest
  end

  # /api/manifest/dash/id/videoplayback
  def self.get_dash_video_playback(env)
    env.response.headers.delete("Content-Type")
    env.response.headers["Access-Control-Allow-Origin"] = "*"
    env.redirect "/videoplayback?#{env.params.query}"
  end

  # /api/manifest/dash/id/videoplayback/*
  def self.get_dash_video_playback_greedy(env)
    env.response.headers.delete("Content-Type")
    env.response.headers["Access-Control-Allow-Origin"] = "*"
    env.redirect env.request.path.lchop("/api/manifest/dash/id")
  end

  # /api/manifest/dash/id/videoplayback && /api/manifest/dash/id/videoplayback/*
  def self.options_dash_video_playback(env)
    env.response.headers.delete("Content-Type")
    env.response.headers["Access-Control-Allow-Origin"] = "*"
    env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
  end

  # /api/manifest/hls_playlist/*
  def self.get_hls_playlist(env)
    response = YT_POOL.client &.get(env.request.path)

    if response.status_code != 200
      haltf env, status_code: response.status_code
    end

    local = env.params.query["local"]?.try &.== "true"

    env.response.content_type = "application/x-mpegURL"
    env.response.headers.add("Access-Control-Allow-Origin", "*")

    manifest = response.body

    if local
      manifest = manifest.gsub(/^https:\/\/\w+---.{11}\.c\.youtube\.com[^\n]*/m) do |match|
        path = URI.parse(match).path

        path = path.lchop("/videoplayback/")
        path = path.rchop("/")

        path = path.gsub(/mime\/\w+\/\w+/) do |mimetype|
          mimetype = mimetype.split("/")
          mimetype[0] + "/" + mimetype[1] + "%2F" + mimetype[2]
        end

        path = path.split("/")

        raw_params = {} of String => Array(String)
        path.each_slice(2) do |pair|
          key, value = pair
          value = URI.decode_www_form(value)

          if raw_params[key]?
            raw_params[key] << value
          else
            raw_params[key] = [value]
          end
        end

        raw_params = HTTP::Params.new(raw_params)
        if fvip = raw_params["hls_chunk_host"].match(/r(?<fvip>\d+)---/)
          raw_params["fvip"] = fvip["fvip"]
        end

        raw_params["local"] = "true"

        "#{HOST_URL}/videoplayback?#{raw_params}"
      end
    end

    manifest
  end

  # /api/manifest/hls_variant/*
  def self.get_hls_variant(env)
    response = YT_POOL.client &.get(env.request.path)

    if response.status_code != 200
      haltf env, status_code: response.status_code
    end

    local = env.params.query["local"]?.try &.== "true"

    env.response.content_type = "application/x-mpegURL"
    env.response.headers.add("Access-Control-Allow-Origin", "*")

    manifest = response.body

    if local
      manifest = manifest.gsub("https://www.youtube.com", HOST_URL)
      manifest = manifest.gsub("index.m3u8", "index.m3u8?local=true")
    end

    manifest
  end
end
