require 'arbre'
require 'arbre/html/text_node'
require 'sinatra/base'
require 'sinatra/cookies'
require 'sinatra/required_params'
require 'json'
require 'i18n'
require 'pstore'
require 'singleton'

VIDEO_ATTRIBUTES =
  %i[
    id
    title
    video_id
    views
    likes
    comments
    description
    thumbnail_url
    created_at
    updated_at
  ].freeze
Video = Struct.new(*VIDEO_ATTRIBUTES)

class VideoList
  @@videos = {}

  def self.convert_json_videos(videos_from_json)
    videos_from_json.collect do |video|
      video.transform_keys!(&:to_sym)
      Video.new(*VIDEO_ATTRIBUTES.collect { |attribute| video[attribute] })
    end
  end

  def self.get_all_videos
    i = 1
    videos = []
    loop do
      begin
        response =
          RestClient.get(
            'https://mock-youtube-api.herokuapp.com/api/videos',
            params: { page: i })
      rescue RestClient::ExceptionWithResponse => e
        error_message = 
        'Unable to complete API request to get all the videos for the search index.' +
        'Error provided: ' + e.response.body
        raise RuntimeError.new(error_message)
      rescue SocketError
        raise RuntimeError.new('Unable to connect to API')
      rescue StandardError
        raise RuntimeError.new('Unable to process all the videos')
      end

      response_body = JSON.parse(response.body)
      break if response_body['videos'].empty?

      total_videos = response_body.dig('meta', 'total').to_i
      retrieved_videos = convert_json_videos(response_body['videos'])
      videos.concat(retrieved_videos)
      i += 1
      break if videos.length >= total_videos
    end
    @@videos = videos.to_h { |video| [video.id, video] }
    videos
  end

  def self.get_video(id:)
    get_all_videos unless defined?(@@videos) || @@videos.nil?
    @@videos[id.to_i]
  end

  def self.get_videos(page:)
    @@videos = {} unless defined?(@@videos) || @@videos.nil?
    begin
      response =
        RestClient.get(
          'https://mock-youtube-api.herokuapp.com/api/videos',
          params: { page: page })
    rescue RestClient::ExceptionWithResponse => e
      error_message = 
        'Unable to complete API request to get all the videos for the search index.' +
        "Status Code: #{e.response.code}. " +
        "Error provided: #{e.response.body}"
      raise RuntimeError.new(error_message)
    rescue SocketError
      raise RuntimeError.new('Unable to connect to API')
    rescue StandardError
      raise RuntimeError.new('Unable to process all the videos')
    end
    response_body = JSON.parse(response.body)
    if !response_body['videos'].empty?
      videos = convert_json_videos(response_body['videos'])
      @@videos.merge!(videos.to_h { |video| [video.id, video] })
      videos
    else
      []
    end
  end
end

class UserStorage
  include Singleton

  def initialize
    @store = PStore.new('user_playlists.pstore')
  end

  def write(key, value)
    @store.transaction { @store[key] = value }
  end

  def read(key)
    @store.transaction(true) { @store.fetch(key, nil) }
  end

  def exists?(key)
    @store.transaction(true) { @store.root?(key) }
  end
end

class User

  private
  def initialize(user_id)
    @id = user_id
    @playlist_collection = PlaylistCollection.new(self)
  end

  public
  def self.load(user_id:)
    unless UserStorage.instance.exists?(user_id)
      user = new(user_id)
      UserStorage.instance.write(user_id, user)
      return user
    end
    user = UserStorage.instance.read(user_id)
    user
  end
  
  attr_reader :id, :playlist_collection

  def save
    UserStorage.instance.write(@id, self)
  end

  def marshal_dump
    {}.tap do |user|
      user[:id] = @id
      user[:playlists] = @playlist_collection.playlists
    end
  end

  def marshal_load(data)
    @id = data[:id]
    @playlist_collection = PlaylistCollection.new(self, data[:playlists])
  end
end

class PlaylistCollection

  def initialize(user, playlists = {})
    @user = user
    @playlists = playlists
  end

  def add(playlist:)
    playlist.user = @user
    @playlists[playlist.id] = playlist
    @user.save
  end

  def delete(playlist:)
    @playlists.delete(playlist.id)
    @user.save
  end

  def get_playlist(id:)
    @playlists[id]
  end

  def get_all_playlists
    @playlists.values
  end

  attr_accessor :playlists
end

class Playlist
  attr_reader :id, :videos
  attr_accessor :name, :user

  def initialize(name:, videos:)
    @id = HumanHash.uuid.first
    @name = name
    videos = [] if videos.nil?
    @videos = videos
  end

  def add(videos_by_id:)
    @videos.concat(videos_by_id)
    @user.save unless @user.nil?
  end

  def remove(video_index)
    @videos.delete_at(video_index)
    @user.save unless @user.nil?
  end

  def change_ordering(new_ordering_by_indices)
    @videos = new_ordering_by_indices.map { |index| @videos[index] }
    @user.save unless @user.nil?
  end

  def each_video_with_index
    @videos.each_with_index do |video_id, index|
      video = VideoList.get_video(id: video_id)
      yield(video, index)
    end
  end
end

class PlaylistManagerApp < Sinatra::Base
  helpers Sinatra::Cookies
  helpers Sinatra::RequiredParams

  use Rack::Session::Cookie, 
        :key          => '_session', 
        :httponly     => true,
        :same_site    => :strict,
        :path         => '/',
        :expire_after => 60 * 60,
        :secret       => 'secret'

  enable :sessions
  enable :logging

  def remove_symbols_and_case(s)
    I18n.transliterate(s).gsub(/[^a-zA-Z\d]/, '').downcase
  end

  def separate_title_into_keyword_set(title)
    title
      .split(/ |-/)
      .map { |s| remove_symbols_and_case(s) }
      .reject(&:empty?)
      .to_set
  end

  def create_index(videos)
    @@title_tokens_to_videos = {} unless defined?(@@title_tokens_to_videos)
    videos.each do |video|
      keywords = separate_title_into_keyword_set(video.title)
      keywords.each do |keyword|
        @@title_tokens_to_videos[keyword] = Set.new unless @@title_tokens_to_videos.has_key?(keyword)
        @@title_tokens_to_videos[keyword].add(video)
      end
    end
    @@sorted_title_tokens = @@title_tokens_to_videos.keys.sort
  end

  before do
    headers 'Access-Control-Allow-Origin' => '*',
            'Access-Control-Allow-Methods' => %w[OPTIONS GET POST PUT DELETE]
    cookies[:user_id] = HumanHash.uuid.first unless cookies.has_key?(:user_id)
  end

  configure do
    I18n.config.available_locales = :en
  end

  not_found do
    @error_message = 'Unable to find resource'
    haml(:error)
  end

  get('/') do
    redirect '/index'
  end

  get('/index') do
    session[:page_number] = 1 unless session.has_key?(:page_number)
    @page_number = session[:page_number]
    begin  
      videos = VideoList.get_all_videos
    rescue Exception => error
      @error_message = error.message
      halt haml(:error)
    end
    create_index(videos) unless defined?(@@sorted_title_tokens) 
    haml(:index)
  end

  def render_video_list(videos, matching_keywords = [])
    Arbre::Context.new do
      unless matching_keywords.empty?
        header do
          h5 { 'closest matching keywords' }
          matching_keywords.each do |keyword|
            mark { keyword }
            text_node ' '
          end
          h4 { "#{videos.length.to_s} result#{videos.length > 1 ? 's' : ''}"}
        end
      end  
      header { h1 { 'No results' } } if videos.empty?
      videos.each do |video|
        aside do
          input(type: 'checkbox',
                name: 'video_ids[]',
                id: "video_id-#{video.id.to_s}",
                value: video.id) {}
          label(for: "video_id-#{video.id.to_s}") { 'Add to playlist' }
          figure { img(src: video.thumbnail_url) {} }
          h3 { video.title }
          para do
            mark { video.views }
            text_node "view#{video.views > 1 ? 's' : ''}"
          end
          para do
            details do
              summary { 'View description' }
              para { video.description }
            end
          end
          section do
            a(href: "/watch/#{video.id.to_s}") { 'Watch' }
          end
        end
      end
    end
  end

  def search_videos(title_query)
    return [[], []] if title_query.empty?

    keywords = separate_title_into_keyword_set(title_query)
    return [[], []] if keywords.empty?

    closest_matching_video_sets_by_keyword =
      keywords
      .collect { |keyword|
        closest_matching_title_token =
          @@sorted_title_tokens.bsearch { |title_token| title_token >= keyword }
        unless closest_matching_title_token.nil?
          [closest_matching_title_token, @@title_tokens_to_videos[closest_matching_title_token]]
        end
      }
      .compact

    closest_matching_keywords = closest_matching_video_sets_by_keyword.map { |keyword, _| keyword }
    closest_matching_video_sets = closest_matching_video_sets_by_keyword.map { |_, video_sets| video_sets }

    matching_videos = closest_matching_video_sets.reduce(&:intersection)

    ranked_video_results = 
      matching_videos
        .partition { |video|
          video_title_transformed = remove_symbols_and_case(video.title)
          title_query_transformed = remove_symbols_and_case(title_query)
          video_title_transformed.include?(title_query_transformed)
        }
        .flatten
    
    [closest_matching_keywords, ranked_video_results]
    # VideoList.videos.select { |video| video.title.downcase.include?(title_query.downcase) }
  end

  get('/index/videos/page/:page_number') do
    required_params :page_number
    page_number = params[:page_number].to_i
    session[:page_number] = page_number
    begin
      current_videos = VideoList.get_videos(page: page_number)
      create_index(current_videos)
      buttons = Arbre::Context.new do
        header do
          if page_number >= 2
            button(
              'onclick' => 'clear_selected_videos()',
              'hx-get' => "/index/videos/page/#{page_number - 1}",
              'hx-trigger' => 'click',
              'hx-target' => '#video_ids') { 'Previous' }
          end
          unless VideoList.get_videos(page: page_number + 1).empty?
            button(
              'onclick' => 'clear_selected_videos()',
              'hx-get' => "/index/videos/page/#{page_number + 1}",
              'hx-trigger' => 'click',
              'hx-target' => '#video_ids') { 'Next' }
          end
        end
      end
    rescue Exception => error
      halt 204, error.message
    end
    videos = render_video_list(current_videos)
    buttons.to_s + videos.to_s
  end

  get('/watch/:id') do
    required_params :id
    id = params['id']
    begin
      @video = VideoList.get_video(id: id)
    rescue Exception => error
      @error_message = error.message
      halt haml(:error)
    end
    haml(:watch)
  end

  get('/search') do
    required_params :title_query
    title_query = params['title_query']
    if title_query.empty?
      (_, _, body) = 
        call env.merge("PATH_INFO" => "/index/videos/page/#{session[:page_number].to_s}")
      body
    else
      (closest_matching_keywords, found_videos) = search_videos(title_query)
      render_video_list(found_videos, closest_matching_keywords)
    end
  end

  get('/playlist-manager') do
    user_data = User.load(user_id: cookies[:user_id])
    @playlists = user_data.playlist_collection.get_all_playlists
    haml(:playlist_manager)
  end

  get('/playlist-viewer/playlist/:playlist_id') do
    required_params :playlist_id
    @playlist_id = params['playlist_id']
    user_data = User.load(user_id: cookies[:user_id])
    playlist = user_data.playlist_collection.get_playlist(id: @playlist_id)
    @has_multiple_videos = playlist.videos.length > 1
    begin
      @video = VideoList.get_video(id: playlist.videos.first)
    rescue Exception => error
      @error_message = error.message
      halt haml(:error)
    end
    haml(:playlist_viewer)
  end

  get('/playlist-viewer/playlist/:playlist_id/video_view/:index') do
    required_params :playlist_id, :index
    playlist_id = params['playlist_id']
    user_data = User.load(user_id: cookies[:user_id])
    index = params['index'].to_i
    begin
      playlist = user_data.playlist_collection.get_playlist(id: playlist_id)
      raise Exception.new('Incorreclty provided playlist id') if playlist.nil?
      video = VideoList.get_video(id: playlist.videos[index])
      raise Exception.new('Incorreclty provided video id') if video.nil?
    rescue Exception => error
      halt 204, error.message
    end
    Arbre::Context.new do
      h2 { video.title }
      section do
        if index >= 1
          button(
            'hx-get' => "/playlist-viewer/playlist/#{playlist_id}/video_view/#{index - 1}",
            'hx-target' => '#view') { 'Previous' }
        end
        iframe(
          'id' => 'ytplayer', 'type' => 'text/html', 'width' => '640', 'height' => '360',
          'src' => "https://www.youtube.com/embed/#{video.video_id}?autoplay=0",
          'frameborder' => '0',
          allowfullscreen: true) {}
        br {}
        if index <= playlist.videos.length - 2
          button(
            'hx-get' => "/playlist-viewer/playlist/#{playlist_id}/video_view/#{index + 1}",
            'hx-target' => '#view') { 'Next' }
        end
      end
    end
  end

  get('/playlist-manager/playlists') do
    user_data = User.load(user_id: cookies[:user_id])
    playlists = user_data.playlist_collection.get_all_playlists
    if playlists.empty?
      Arbre::Context.new do
        option(value: '', disabled: true, selected: false, hidden: true)
      end
    else
      Arbre::Context.new do
        playlists.each do |playlist|
          option(value: playlist.id) { playlist.name }
        end
      end
    end
  end

  post('/playlist-manager/playlist') do
    required_params :new_playlist_name
    video_ids = params['video_ids']
    user_data = User.load(user_id: cookies[:user_id])
    playlist_name = params['new_playlist_name']
    video_ids = [] if video_ids.nil? || video_ids.empty?
    new_playlist = Playlist.new(name: playlist_name, videos: video_ids) # create playlist with no videos if necessary
    user_data.playlist_collection.add(playlist: new_playlist)
    playlists = user_data.playlist_collection.get_all_playlists
    Arbre::Context.new do
      option(value: new_playlist.id) { new_playlist.name } # show the mru playlist first
      playlists.each do |playlist|
        option(value: playlist.id) { playlist.name } if playlist.id != new_playlist.id
      end
    end
  end

  put('/playlist-manager/playlist') do
    required_params :selected_playlist, :video_ids
    selected_playlist_id = params['selected_playlist']
    video_ids = params['video_ids']
    user_data = User.load(user_id: cookies[:user_id])
    playlist_to_update = user_data.playlist_collection.get_playlist(id: selected_playlist_id)
    playlist_to_update.add(videos_by_id: video_ids)
    playlists = user_data.playlist_collection.get_all_playlists
    Arbre::Context.new do
      option(value: selected_playlist_id) { playlist_to_update.name } # show the mru playlist first
      playlists.each do |playlist|
        option(value: playlist.id) { playlist.name } if playlist.id != selected_playlist_id
      end
    end
  end

  get('/playlist-manager/') do
    user_data = User.load(user_id: cookies[:user_id])
    @playlists = user_data.playlist_collection.get_all_playlists
    haml(:playlist_manager)
  end

  get('/playlist-manager/edit-playlist/:playlist_id') do
    required_params :playlist_id
    user_data = User.load(user_id: cookies[:user_id])
    playlist_id = params['playlist_id']
    @playlist = user_data.playlist_collection.get_playlist(id: playlist_id)
    haml(:playlist_editor)
  end

  delete('/playlist-manager/playlist/:playlist_id') do
    required_params :playlist_id
    playlist_id = params['playlist_id']
    user_data = User.load(user_id: cookies[:user_id])
    playlist = user_data.playlist_collection.get_playlist(id: playlist_id)
    user_data.playlist_collection.delete(playlist: playlist)
    ['']
  end

  put('/playlist-manager/edit-playlist/:playlist_id') do
    required_params :videos, :playlist_id
    videos_by_index = params['videos'].map(&:to_i)
    playlist_id = params['playlist_id']
    user_data = User.load(user_id: cookies[:user_id])
    playlist = user_data.playlist_collection.get_playlist(id: playlist_id)
    playlist.change_ordering(videos_by_index)
    Arbre::Context.new do
      playlist.each_video_with_index do |video, index|
        div do
          input(type: 'hidden', name: 'videos[]', value: index.to_s) {}
          text_node "#{(index + 1).to_s}. #{video.title}"
        end
      end
    end
  end

  get('/playlist-manager/edit-playlist/:playlist_id/reorder_view') do
    required_params :playlist_id
    playlist_id = params[:playlist_id]
    user_data = User.load(user_id: cookies[:user_id])
    playlist = user_data.playlist_collection.get_playlist(id: playlist_id)
    Arbre::Context.new do
      button(
        'hx-get' => "/playlist-manager/edit-playlist/#{playlist_id}/delete_view",
        'hx-trigger' => 'click',
        'hx-target' => '#main_view') { 'Done Reordering' }
      br {}
      form(class: 'sortable', 'hx-put' => "/playlist-manager/edit-playlist/#{playlist_id}", 'hx-trigger' => 'end') do
        playlist.each_video_with_index do |video, index|
          div do
            input(type: 'hidden', name: 'videos[]', value: index.to_s) {}
            text_node "#{(index + 1).to_s}. #{video.title}"
          end
        end
      end
    end
  end

  get('/playlist-manager/edit-playlist/:playlist_id/delete_view') do
    required_params :playlist_id
    playlist_id = params[:playlist_id]
    user_data = User.load(user_id: cookies[:user_id])
    playlist = user_data.playlist_collection.get_playlist(id: playlist_id)
    Arbre::Context.new do
      button(
        'hx-get' => "/playlist-manager/edit-playlist/#{playlist_id}/reorder_view",
        'hx-trigger' => 'click',
        'hx-target' => '#main_view') { 'Reorder' }
      br {}
      table do
        thead do
          tr do
            td {}
            td { 'Playlist name' }
            td {}
          end
        end
        tbody('hx-confirm' => 'Are you sure you want delete?', 'hx-swap' => 'innerHTML',
              'id' => 'deletion_video_list') do
          playlist.each_video_with_index do |video, index|
            tr do
              td { (index + 1).to_s }
              td { video.title }
              td do
                button(
                  'hx-delete' => "/playlist-manager/edit-playlist/#{playlist.id}/video/#{index}",
                  'hx-trigger' => 'click',
                  'hx-target' => '#deletion_video_list') { 'Delete' }
              end
            end
          end
        end
      end
    end
  end

  delete('/playlist-manager/edit-playlist/:playlist_id/video/:index') do
    required_params :playlist_id, :index
    playlist_id = params[:playlist_id]
    video_index = params[:index].to_i
    user_data = User.load(user_id: cookies[:user_id])
    playlist = user_data.playlist_collection.get_playlist(id: playlist_id)
    playlist.remove(video_index)
    Arbre::Context.new do
      playlist.each_video_with_index do |video, index|
        tr do
          td { (index + 1).to_s }
          td { video.title }
          td do
            button(
              'hx-delete' => "/playlist-manager/edit-playlist/#{playlist.id}/video/#{index}",
              'hx-trigger' => 'click',
              'hx-target' => '#deletion_video_list') { 'Delete' }
          end
        end
      end
    end
  end
end
