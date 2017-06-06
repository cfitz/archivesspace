require 'config/config-distribution'
AppConfig[:frontend_proxy_url] = 'https://aspace.for/life'
require File.expand_path("../../config/environment", __FILE__)

require 'rspec/rails'
require 'capybara/rails'


require 'jsonmodel'
require 'client_enum_source'
JSONModel::init(:client_mode => false, :strict_mode => false, :enum_source => ClientEnumSource.new)
include JSONModel
