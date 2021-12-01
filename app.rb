require 'telegram/bot'
require 'dotenv/load'
require 'rest-client'
require 'redis-rails'
require 'jsonpath'
require 'mongoid'
require 'logger'
require 'redis'
require 'json'
require 'i18n'


bot = Telegram::Bot::Client.new(ENV['BOT_TOKEN'])

logger = Logger.new(STDOUT)

I18n.load_path << Dir[File.expand_path("locales") + "/*.yml"]
I18n.default_locale = :en

# https://api.faforever.com/data/player?fields%5Bplayer%5D=login&filter=login%3D%3DKaziNak
# https://www.faforever.com/lobby_api?resource=lobby
# https://api.faforever.com/data/player/342963


def faf_player? name
  response = RestClient.get "https://api.faforever.com/data/player", {params: {'fields[player]': 'login', 'filter': "login==#{name}"}}
  name == JsonPath.new('$.data[0].attributes.login')[response].first
end

def faf_lobby
  response = RestClient.get "https://www.faforever.com/lobby_api?resource=lobby"
  JSON.parse(response)
end

def teams_players teams
  teams.map(&:flatten).flatten.reject{|i| i.match(/^(\d)+$/)  }
end


Mongoid.configure do |config|
  config.clients.default = {
    hosts: [ "#{ENV['MONGO_HOST']}:27017"],
    database: ENV['MONGO_DATABASE'],
    options: {
      user: ENV['MONGO_USER'],
      password: ENV['MONGO_PASSWORD'],
      auth_source: 'admin',
      auth_mech: :scram
    }
  }
  config.log_level = :warn
end


class Chat
  include Mongoid::Document
  field :locale, type: String
  field :player, type: String
  field :lobby, type: Integer # последнее (текущее) лобби игрока
  field :lobby_at, type: DateTime # когда было выслано последнее сообщение о заполненном лобби
  field :maps, type: Set
end


class WebhooksController < Telegram::Bot::UpdatesController
  include Telegram::Bot::UpdatesController::MessageContext

  use_session!
  self.session_store = :redis_store, { url: ENV['REDIS_URL'] }

  around_action :with_locale

  def start!(*)
    respond_with :message, text: t('.commands')
  end


  def setplayer!(*args)
    if args.any?
      player = args.first
      if faf_player? player
        store.update(player: player)
        respond_with :message, text: t('.success', player: player)
      else
        respond_with :message, text: t('.notfound', player: player) 
      end
    else
      respond_with :message, text: t('.respond')
      save_context :setplayer!
    end
  end


  def unsetplayer!(*args)
    store.update(player: nil)
    respond_with :message, text: t('.notice')
  end


  def player!(*)
    player = store.player
    reply = player || t('.notfound')
    respond_with :message, text: reply
  end


  def language!(*args)
    buttons = I18n.available_locales.map do |locale|
      language = I18n.with_locale(locale) { t('language') }
      {text: language, callback_data: "locale #{locale}"}
    end
    respond_with :message, text: t('.prompt'), reply_markup: {
      inline_keyboard: [buttons]
    }
  end

  
  def callback_query(data)
    
    if data.start_with? 'locale '
      locale = data.split(' ').last
      if I18n.available_locales.include? locale.to_sym
        store.update(locale: locale)
        answer_callback_query I18n.with_locale(locale) { t('.locale') }, show_alert: true
      end
    end
    
  end

  
  private


  def store
    Chat.find_or_create_by(id: chat['id']) {|doc| doc.locale = from['language_code'] } 
  end


  def with_locale(&block)
    I18n.with_locale(locale_for_update, &block)
  end


  def locale_for_update
    if store['locale']
      store.locale
    elsif from
      from['language_code']
    elsif chat
      chat['language_code'] # вот тут я не уверен
    end
  end

end



# tracking lobby loop
Thread.new do
  while true

    begin
      faf_lobby.each do |lobby|
        next if lobby['state'] != 'open'

        all_players = teams_players lobby['teams']
        
        Chat.in(player: all_players).each do |chat|
          I18n.locale = chat.locale
          chat.update(lobby: lobby['uid']) if lobby['uid'] != chat.lobby

          observers = lobby['teams']['-1'] || []
          lobby_is_full = all_players.count - observers.count >= lobby['max_players']
          
          # send notify if lobby full
          # reply notify after 90 seconds 
          is_time_to_notify = chat.lobby_at ? Time.now - 90.seconds > chat.lobby_at : true
          if lobby_is_full && is_time_to_notify
            chat.update(lobby_at: Time.now)
            bot.send_message(chat_id: chat.id, text: I18n.t('.lobby_filled', lobby: lobby['title']))
          elsif !lobby_is_full # if lobby not full now, reset time
            chat.update(lobby_at: nil) if chat.lobby_at
          end

        end
      end
    rescue => e
      logger.error e.message
      logger.error e.backtrace.join("\n")
    end
    
    sleep 3
  end
end


# bot poller-mode
poller = Telegram::Bot::UpdatesPoller.new(bot, WebhooksController, logger: logger)
poller.start
