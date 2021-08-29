require "yaml"

struct Config
  module StringConverter
    def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : String
      String.new(ctx, node)
    end
  end
  module HashConverter(Converter)
    def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : Hash
      type = Hash(String, typeof(Converter.from_yaml(ctx, node)))
      case node
      when YAML::Nodes::Scalar # maybe empty, treat as empty anyways
        type.new
      when YAML::Nodes::Mapping
        hash = type.new
        node.each do |knode, vnode|
          key = String.new(ctx, knode)
          value = Converter.from_yaml(ctx, vnode)
          hash[key] = value
        end
        hash
      else
        node.raise "Expected mapping, not #{node.class}"
      end
    end
  end
  module Base64Decoder
    def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : Bytes
      unless node.is_a?(YAML::Nodes::Scalar)
        node.raise "Expected scalar, not #{node.class}"
      end
      Base64.decode(node.value)
    end
  end
  struct Bind
    include YAML::Serializable
    property host : String
    property port : Int32
    property unix : String
    property perm : Int16
  end
  struct MasterAuth
    include YAML::Serializable
    property passphrase : String
    @[YAML::Field(converter: Config::HashConverter(Config::StringConverter))]
    property keys       : Hash(String, String)
  end
  include YAML::Serializable
  property bind       : Bind
  property masterauth : MasterAuth
end

