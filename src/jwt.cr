require "jwt_mapping"

class MasterToken
  include JWT::Token
  property room_id : String
  property command : String

  def initialize(@room_id, @command)
  end

  def self.from_jwt(token : String, keys : Hash(String, String))
    self.from_jwt(token) do |header, payload|
      if header["alg"].as_s? == "ES256"
        key = keys[payload.iss]?
        raise JWT::VerificationError.new "no key" if key.nil?
        key.not_nil!
      else
        raise JWT::UnsupportedAlgorithmError.new "We currently accept ES256 only"
      end
    end
  end
end

