# Copyright 2015 EPAM Systems
#
#
# This file is part of Report Portal.
#
# Report Portal is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ReportPortal is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with Report Portal.  If not, see <http://www.gnu.org/licenses/>.

require 'tempfile'
require 'mime/types'
require 'cgi'
require 'netrc'
require 'set'

# Monkey-patch for RestClient::Request so that we prevent the StructuredWarnings message when using `warn`
module RestClient
  class Request

    # Generate headers for use by a request. Header keys will be stringified
    # using `#stringify_headers` to normalize them as capitalized strings.
    #
    # The final headers consist of:
    #   - default headers from #default_headers
    #   - user_headers provided here
    #   - headers from the payload object (e.g. Content-Type, Content-Lenth)
    #   - cookie headers from #make_cookie_header
    #
    # @param [Hash] user_headers User-provided headers to include
    #
    # @return [Hash<String, String>] A hash of HTTP headers => values
    #
    def make_headers(user_headers)
      headers = stringify_headers(default_headers).merge(stringify_headers(user_headers))

      # override headers from the payload (e.g. Content-Type, Content-Length)
      if @payload
        payload_headers = @payload.headers

        # Warn the user if we override any headers that were previously
        # present. This usually indicates that rest-client was passed
        # conflicting information, e.g. if it was asked to render a payload as
        # x-www-form-urlencoded but a Content-Type application/json was
        # also supplied by the user.
        payload_headers.each_pair do |key, val|
          if headers.include?(key) && headers[key] != val
            $logger.warn("[RestClient::Request] Overriding #{key.inspect} header #{headers.fetch(key).inspect} with #{val.inspect} due to payload")
          end
        end

        headers.merge!(payload_headers)
      end

      # merge in cookies
      cookies = make_cookie_header
      if cookies && !cookies.empty?
        if headers['Cookie']
          $logger.warn('[RestClient::Request] Overriding "Cookie" header with :cookies option')
        end
        headers['Cookie'] = cookies
      end

      headers
    end
  end
end
