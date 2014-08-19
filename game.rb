APP_ENV = ENV['RACK_ENV'].to_sym || :development

require 'bundler'
Bundler.require(:default, APP_ENV)

require 'json'

ANSI_COLORS = [:red, :yellow, :green, :cyan, :magenta, :blue] # I'm goy

module Groupme
  extend self

  ACCESS_TOKEN = ENV['GROUPME_ACCESS_TOKEN'] || (raise 'GROUPME_ACCESS_TOKEN must be set')
  GROUP_ID = ENV['GROUPME_GROUP_ID'] || (raise 'GROUPME_GROUP_ID must be set')
  BOT_ID = ENV['GROUPME_BOT_ID'] || (raise 'GROUPME_BOT_ID must be set')

  def post_message(text)
    if APP_ENV == :development
      puts text.ansi(ANSI_COLORS.shuffle.first)
      return false
    end

    url = "https://api.groupme.com/v3/bots/post?token=#{ACCESS_TOKEN}"
    body = {
      text: text,
      bot_id: BOT_ID
    }.to_json
    Typhoeus.post(url, body: body)
  end

end

module StringCleaner
  extend self

  def clean(string)
    str = string.dup
    str.gsub!(/ (and|&) /, ' ')
    str = Sanitize.fragment(str)
    str = str.downcase.gsub(/[^\w ]/, '')[/^(?:(?:the|an?) )? *([a-z \.]+)/i][$1]
    str.gsub!('-', ' ')
    str.gsub!(/s$/, '') # de-pluralize
    str.squeeze(' ').strip
  end

end

class Trivia

  SECS_TO_ANSWER = 30
  QUESTION_FILE = File.expand_path('../questions.json', __FILE__)
  QUESTIONS = JSON.parse(File.read(QUESTION_FILE)) # this will use nearly 1mb of RAM

  attr_reader :current_question

  def initialize(points)
    @points = points
    load_question_from_file
  end

  def ask_question
    set_question generate_question.merge('asked_at' => Time.now)

    question_msg = "[Q] #{@current_question['Q']}\n(#{SECS_TO_ANSWER}s to answer)"

    Groupme.post_message(question_msg)
  end

  def try_answer(user_id, username, answer_attempt)
    answer_token = StringCleaner.clean(@current_question['A'])
    answer_attempt_token = StringCleaner.clean(answer_attempt)

    if seconds_remaining.zero?
      post_timer_ran_out(answer_token)
      set_question(nil)
    elsif answer_token == answer_attempt_token

      @points.add_points_to(user_id, 1)

      post_answer_correct(user_id, username, answer_attempt_token)
      set_question(nil)
    else
      post_answer_incorrect(user_id, username, answer_attempt_token)
    end

  end

  def active_question?
    if @current_question
      if seconds_remaining.zero?
        post_timer_ran_out(@current_question['A'])
        @current_question = nil
        false
      else
        true
      end
    else
      false
    end
  end

  def seconds_remaining
    secs = SECS_TO_ANSWER - (Time.now - Time.parse(@current_question['asked_at'].to_s))
    [secs.ceil, 0].max
  end

  private

  def post_timer_ran_out(answer)
    Groupme.post_message("[x] Timer ran out, answer was \"#{answer}\"")
  end

  def post_answer_correct(user_id, username, answer)
    Groupme.post_message("[A: #{username} (#{@points.points_for(user_id)}p)] Yes, #{@current_question['A']}")
  end

  def post_answer_incorrect(user_id, username, answer)
    Groupme.post_message("[A: #{username} (#{@points.points_for(user_id)}p)] Nope, \"#{answer}\" is wrong. #{seconds_remaining}s left to answer...")
  end

  def generate_question
    QUESTIONS.shuffle.shift # shifting will remove the question from the questions array
  end

  def set_question(question)
    @current_question = question
    write_question_to_file
  end

  def write_question_to_file
    File.open(File.expand_path('../current_question.json', __FILE__), 'w') do |f|
      f.write(current_question.to_json)
    end
  end

  def load_question_from_file
    @current_question = JSON.parse(File.read(File.expand_path('../current_question.json', __FILE__))) rescue nil
  end

end

class UserPoints

  FILE = File.expand_path('../user_points.json', __FILE__)

  attr_reader :points

  def initialize
    load_points_from_file
  end

  def add_points_to(user_id, amount)
    @points[user_id] ||= 0
    @points[user_id] += amount
    write_points_file
  end

  def points_for(user_id)
    @points[user_id] || 0
  end

  private

  def write_points_file
    File.open(FILE, 'w') {|f| f.write(points.to_json) }
  end

  def load_points_from_file
    @points = JSON.parse(File.read(FILE)) rescue {}
  end

end


# Sinatra stuffe

configure do
  set :trivia, Trivia.new(UserPoints.new)
end

post '/submit_message' do

  message = JSON.parse(request.body.read)
  text = message['text']

  if !settings.trivia.active_question? && text =~ /^[\\\/]trivia *$/i
    settings.trivia.ask_question

    # NOTE this is insane... keeping thread open for timer
    # while settings.trivia.active_question?
    #   puts "#{settings.trivia.seconds_remaining}s remaining to answer"
    #   sleep 1
    # end

  elsif settings.trivia.active_question?

    if text =~ /^[\\\/](?:a|answer) +(.+) *$/i # answering
      username = message['name']
      user_id = message['user_id']

      settings.trivia.try_answer(user_id, username, $1)
    else
      puts 'Question still active'.ansi(:red)
    end

  else
    puts "nothing".ansi(:red)
  end

  200
end
