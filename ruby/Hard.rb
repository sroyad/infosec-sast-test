require 'net/http'
uri = URI(ARGV[0])
puts Net::HTTP.get(uri)  # SSRF
