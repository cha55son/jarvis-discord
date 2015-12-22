require 'discordrb'
require 'aws-sdk'

bot = Discordrb::Bot.new ENV['DISCORD_BOT_EMAIL'], ENV['DISCORD_BOT_PASSWORD']
se_mod = "#{ENV['BOT_NAME']} (se|space-engineers|space engineers)"

@logger = Logger.new(File.dirname(File.dirname(__FILE__)) + '/log/bot.log', 10, 1049000000)
@logger.level = "Logger::#{ENV['LOGGER_LEVEL']}".constantize
@inst_id = ENV['AWS_SE_INSTANCE_ID']
@ec2 = Aws::EC2::Client.new({
    region: ENV['AWS_REGION'], 
    credentials: Aws::Credentials.new(ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
})
@server_expiry_seconds = (ENV['AWS_SERVER_EXPIRATION_SECONDS'] || 3600).to_i
@server_expiry_seconds_notif = (ENV['AWS_SERVER_EXPIRATION_SECONDS_NOTIF'] || 300).to_i
@threads = []

def get_instance
    @ec2.describe_instances({ instance_ids: [@inst_id] }).reservations[0].instances[0]
end
# Would this block the server?
def poll_til_status(status)
    300.times do |i|
        sleep 1
        status_name = get_instance.state.name
        @logger.debug "Polling #{i} - Got status #{status_name}"
        return true if status_name == status
    end
    false
end
def stop_server(event) 
    if get_instance.state.name != 'running'
        event.respond "**Warning!** The Space Engineers server is not running therefore i'm refusing to stop it."
        return false
    end
    @ec2.stop_instances({ instance_ids: [@inst_id] })
    event.respond "Stopping the Space Engineers server! Waiting on the server status..."
    if poll_til_status('stopped')
        event.respond "👍 The Space Engineers server is stopped!"
    else
        event.respond "**Warning!** The Space Engineers server took longer than 5 minutes to stop."
    end
    true
end
def humanize(secs)
    ret = [[60, :seconds], [60, :minutes], [24, :hours], [1000, :days]].map do |count, name|
        if secs > 0
            secs, n = secs.divmod(count)
            n == 0 ? nil : "#{n.to_i} #{name}"
        end
    end
    ret.compact.reverse.join(' ')
end
# Fire off a new thread so it doesn't block. Once the expiry time is up stop the server.
def handle_expiration(event)
    @threads << Thread.new do
        first_take = @server_expiry_seconds - (2 * @server_expiry_seconds_notif)
        @logger.info "Handle expiration: Sleeping for #{humanize(first_take)}."
        sleep first_take
        event.respond "The Space Engineers server will shutdown in #{humanize(2 * @server_expiry_seconds_notif)}."
        event.respond "Run `#{ENV['BOT_NAME']} se renew` to reset the expiration."
        @logger.info "Handle expiration: Sleeping for #{humanize(@server_expiry_seconds_notif)}."
        sleep @server_expiry_seconds_notif
        event.respond "**Last Warning!** The Space Engineers server will shutdown in #{humanize(@server_expiry_seconds_notif)}."
        event.respond "Run `#{ENV['BOT_NAME']} se renew` to reset the expiration."
        @logger.info "Handle expiration: Sleeping for #{humanize(@server_expiry_seconds_notif)}."
        sleep @server_expiry_seconds_notif
        @logger.info "Handle expiration: Server is expired run shutdown functionality!"
        stop_server(event)
    end
end

# Bot commands 
# ====================================================
bot.message(with_text: /^#{ENV['BOT_NAME']} help/i) do |event|
    event.respond "" +
"""
**#{ENV['BOT_NAME']} se status** - Get the current status of the Space Engineers server.
**#{ENV['BOT_NAME']} se start** - Start the Space Engineers server. The server will be shutdown once the expiration period (#{humanize(@server_expiry_seconds)}) is met.
**#{ENV['BOT_NAME']} se renew** - Renews the Space Engineers server's expiration period (#{humanize(@server_expiry_seconds)}).
**#{ENV['BOT_NAME']} se stop** - Stops the Space Engineers server.
"""
end
bot.message(with_text: /^#{se_mod} status/i) do |event|
    @logger.info "Someone requested the status of the SE server"
    event.respond "The Space Engineers server is currently **#{get_instance.state.name}**."
end
bot.message(with_text: /^#{se_mod} start/i) do |event|
    @logger.info "Someone wants to start the SE server"
    if get_instance.state.name != 'stopped'
        event.respond "**Warning!** The Space Engineers server is not stopped therefore i'm refusing to start it."
        next
    end
    @ec2.start_instances({ instance_ids: [@inst_id] })
    event.respond "Starting the Space Engineers server! Waiting on the server status..."
    if poll_til_status('running')
        event.respond "👍 The Space Engineers server is running!"
    else
        event.respond "**Warning!** The Space Engineers server took longer than 5 minutes to start."
    end
    handle_expiration(event)
    event.respond "The Space Engineers server will shutdown after #{humanize(@server_expiry_seconds)}."
end
bot.message(with_text: /^#{se_mod} stop/i) do |event|
    @logger.info "Someone wants to stop the SE server"
    @logger.debug "Killing all threads!"
    if get_instance.state.name != 'running'
        event.respond "**Warning!** The Space Engineers server is not running therefore i'm refusing to stop it."
        next
    end
    @threads.each(&:exit)
    stop_server(event)
end
bot.message(with_text: /^#{se_mod} renew/i) do |event|
    @logger.info "Someone wants to renew the SE server"
    if get_instance.state.name != 'running'
        event.respond "**Warning!** The Space Engineers server is not running therefore i'm refusing to renew it."
        next
    end
    @logger.debug "Killing all threads!"
    @threads.each(&:exit)
    handle_expiration(event)
    event.respond "👍 The Space Engineers server was renewed for another #{humanize(@server_expiry_seconds)}!"
end

bot.run
