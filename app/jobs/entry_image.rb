class EntryImage
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(public_id, image = nil)
    @entry = Entry.find_by_public_id(public_id)
    @image = image
    if @image
      receive
    elsif !@entry.processed_image?
      schedule
    end
  rescue ActiveRecord::RecordNotFound
  end

  def schedule
    if job = build_job
      Sidekiq::Client.push(
        "args" => job,
        "class" => "FindImage",
        "queue" => "image_parallel",
        "retry" => false
      )
    end
  end

  def build_job
    image_urls = []
    entry_url = nil
    preset_name = "primary"
    if @entry.tweet?
      tweets = []
      tweets.push(@entry.main_tweet)
      tweets.push(@entry.main_tweet.quoted_status) if @entry.main_tweet.quoted_status?
      tweet = tweets.find do |tweet|
        tweet.media?
      end
      image_urls = [tweet.media.first.media_url_https.to_s] unless tweet.nil?
    elsif @entry.youtube?
      image_urls = [@entry.fully_qualified_url]
      preset_name = "youtube"
    else
      entry_url = @entry.fully_qualified_url if same_domain?
      image_urls = find_image_urls
    end

    if image_urls.present? || entry_url.present?
      [@entry.public_id, preset_name, image_urls, entry_url]
    end
  end

  def same_domain?
    entry_host = Addressable::URI.heuristic_parse(@entry.fully_qualified_url).host
    feed_host = @entry.feed.host
    entry_host == feed_host
  end

  def receive
    @entry.update(image: @image)
  end

  def find_image_urls
    Nokogiri::HTML5(@entry.content).css("img, iframe, video").each_with_object([]) do |element, array|
      source = case element.name
        when "img" then element["src"]
        when "iframe" then element["src"]
        when "video" then element["poster"]
      end

      if source.present?
        array.push @entry.rebase_url(source)
      end
    end
  end

  def entry=(entry)
    @entry = entry
  end
end
