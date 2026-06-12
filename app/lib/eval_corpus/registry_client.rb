# frozen_string_literal: true

require "erb"
require "open3"

module EvalCorpus
  # Polite fetcher for TTB's Public COLA Registry. Every fetched page and
  # image is cached under tmp/eval_cache/<ttb_id>/ so re-runs are offline;
  # live requests identify themselves and pause between calls.
  class RegistryClient
    BASE = "https://www.ttbonline.gov/colasonline"
    USER_AGENT = "label-verifier-eval/1.0 (research; contact via repository)"
    REQUEST_PAUSE_SECONDS = 1.2

    def initialize(cache_dir:)
      @cache_dir = Pathname(cache_dir)
      @last_request_at = nil
      @cookie_jar = nil
      @session_referer = nil
    end

    # The printable TTB F 5100.31 view: application fields, checked type/
    # source boxes, class/type description, and the label image links.
    def form_html(ttb_id)
      cached_text(ttb_id, "form.html") do
        get("/viewColaDetails.do?action=publicFormDisplay&ttbid=#{ttb_id}")
      end
    end

    # The COLA detail view: origin code and wine vintage, which the
    # printable form does not carry.
    def detail_html(ttb_id)
      cached_text(ttb_id, "detail.html") do
        get("/viewColaDetails.do?action=publicDisplaySearchAdvanced&ttbid=#{ttb_id}")
      end
    end

    # The form page's attachment hrefs carry raw filenames ("CE VALLEE
    # LOIRE.png"); curl rejects unencoded spaces outright, so the request
    # path is rebuilt with percent-encoded query values.
    def self.attachment_request_path(path)
      filename = path[/filename=([^&]+)/, 1].to_s
      raise ArgumentError, "attachment path carries no filename: #{path.inspect}" if filename.empty?

      filetype = path[/filetype=([^&]+)/, 1] || "l"
      "publicViewAttachment.do?filename=#{ERB::Util.url_encode(filename)}&filetype=#{ERB::Util.url_encode(filetype)}"
    end

    # Label image bytes for a publicViewAttachment path from the form
    # page. The endpoint requires the session cookie (and referer) of a
    # prior detail-page request; without them it returns an HTML error
    # page with a 200.
    def attachment(ttb_id, path)
      filename = path[/filename=([^&]+)/, 1].to_s
      raise ArgumentError, "attachment path carries no filename: #{path.inspect}" if filename.empty?

      request_path = self.class.attachment_request_path(path)
      cached_binary(ttb_id, filename) do
        ensure_session(ttb_id)
        bytes = get(request_path)
        raise FetchError, "#{path}: registry returned an error page instead of image bytes" if bytes.lstrip.start_with?("<")

        bytes
      end
    end

    private

    def cached_text(ttb_id, name, &fetch)
      cached_binary(ttb_id, name, &fetch).force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
    end

    def cached_binary(ttb_id, name)
      path = @cache_dir.join(ttb_id.to_s, name)
      return path.binread if path.exist?

      bytes = yield
      path.dirname.mkpath
      path.binwrite(bytes)
      bytes
    end

    # Transport is curl, not Net::HTTP: ttbonline.gov serves an incomplete
    # certificate chain that Ruby's OpenSSL rejects with every local CA
    # bundle, while curl resolves the intermediates through the system
    # trust store. Shelling out matches the app's pattern for external
    # binaries (magick, pdftoppm).
    # A live form-page request establishes the registry session the
    # attachment endpoint demands; one per client instance suffices.
    def ensure_session(ttb_id)
      return if @session_referer

      url = "#{BASE}/viewColaDetails.do?action=publicFormDisplay&ttbid=#{ttb_id}"
      @session_referer = url
      get("viewColaDetails.do?action=publicFormDisplay&ttbid=#{ttb_id}")
    end

    # Transport is curl, not Net::HTTP: ttbonline.gov serves an incomplete
    # certificate chain that Ruby's OpenSSL rejects with every local CA
    # bundle, while curl resolves the intermediates through the system
    # trust store. Shelling out matches the app's pattern for external
    # binaries (magick, pdftoppm).
    def get(path_and_query)
      pause
      url = "#{BASE}/#{path_and_query.delete_prefix('/').sub(/\Acolasonline\//, '')}"
      command = [
        "curl", "--silent", "--show-error", "--fail", "--max-time", "60",
        "--user-agent", USER_AGENT,
        "--cookie", cookie_jar, "--cookie-jar", cookie_jar
      ]
      command += [ "--referer", @session_referer ] if @session_referer
      stdout, stderr, status = Open3.capture3(*command, url, binmode: true)
      raise FetchError, "#{url}: curl failed: #{stderr.lines.last.to_s.strip}" unless status.success?

      stdout
    end

    def cookie_jar
      @cookie_jar ||= Tempfile.create("ttb-cookies").path
    end

    def pause
      elapsed = @last_request_at ? Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_request_at : nil
      sleep(REQUEST_PAUSE_SECONDS - elapsed) if elapsed && elapsed < REQUEST_PAUSE_SECONDS
      @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    class FetchError < StandardError; end
  end
end
