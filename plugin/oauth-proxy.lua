local _M = { conf = {} }
local aes = require "resty.aes"

local function array_has_value(arr, val)
    for index, value in ipairs(arr) do
        if value == val then
            return true
        end
    end

    return false
end

local function error_response(status, code, message, config)

    local jsonData = '{"code":"' .. code .. '", "message":"' .. message .. '"}'
    ngx.status = status
    ngx.header['content-type'] = 'application/json'

    if config.trusted_web_origins then

        local origin = ngx.req.get_headers()["origin"]
        if origin and array_has_value(config.trusted_web_origins, origin) then
            ngx.header['Access-Control-Allow-Origin'] = origin
            ngx.header['Access-Control-Allow-Credentials'] = 'true'
        end
    end

    ngx.say(jsonData)
    ngx.exit(status)
end

local function unauthorized_request_error_response(config)
    error_response(ngx.HTTP_UNAUTHORIZED, "unauthorized", "The request failed cookie authorization", config)
end

local function split(inputstr, sep)
    local result={}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        table.insert(result, str)
    end

    return result
end

local function from_hex(str)
    return (str:gsub('..', function (cc)
        return string.char(tonumber(cc, 16))
    end))
end

local function decrypt_cookie(encrypted_cookie, encryption_key)
    local encrypted = ngx.unescape_uri(encrypted_cookie)

    if not string.find(encrypted, ":") then
        ngx.log(ngx.WARN, "Malformed cookie received with no valid separator")
        return nil
    end

    local parts = split(encrypted, ":")
    local iv = from_hex(parts[1])
    local data = from_hex(parts[2])

    local cipher = aes.cipher(256)
    local aes_256_cbc_md5, err = aes:new(encryption_key, nil, cipher, { iv=iv })

    if err then
        ngx.log(ngx.WARN, "Error creating decipher: " .. err)
        return nil
    end

    return aes_256_cbc_md5:decrypt(data)
end

--
-- The public entry point to decrypt a secure cookie from SPAs and forward the contained access token
--
function _M.run(config)

    -- Ignore pre-flight requests from browser clients
    local method = ngx.req.get_method():upper()
    if method == "OPTIONS" then
        return
    end

    -- If there is already a bearer token, eg for mobile clients, return immediately
    -- Note that the target API must always digitally verify the JWT access token
    local auth_header = ngx.var.http_authorization
    if auth_header and string.len(auth_header) > 7 and string.lower(string.sub(auth_header, 1, 7)) == 'bearer ' then
        return
    end

    -- For cookie requests, verify the web origin in line with OWASP CSRF best practices
    if config.trusted_web_origins then

        local web_origin = ngx.req.get_headers()["origin"]
        if not web_origin or not array_has_value(config.trusted_web_origins, web_origin) then
            ngx.log(ngx.WARN, "The request was from an untrusted web origin")
            unauthorized_request_error_response(config)
        end
    end

    -- For data changing requests do double submit cookie verification in line with OWASP CSRF best practices
    if method == "POST" or method == "PUT" or method == "DELETE" or method == "PATCH" then

        local csrf_cookie_name = "cookie_" .. config.cookie_name_prefix .. "-csrf"
        local csrf_cookie = ngx.var[csrf_cookie_name]
        if not csrf_cookie then
            ngx.log(ngx.WARN, "No CSRF cookie was sent with the request")
            unauthorized_request_error_response(config)
        end

        local csrf_token = decrypt_cookie(csrf_cookie, config.encryption_key)
        if not csrf_token then
            ngx.log(ngx.WARN, "Error decrypting CSRF cookie")
            unauthorized_request_error_response(config)
        end

        local csrf_header = ngx.req.get_headers()["x-" .. config.cookie_name_prefix .. "-csrf"]
        if not csrf_header or csrf_header ~= csrf_token  then
            ngx.log(ngx.WARN, "Invalid or missing CSRF request header")
            unauthorized_request_error_response(config)
        end
    end

    -- Next verify that the main cookie was received and get the access token
    local at_cookie_name = "cookie_" .. config.cookie_name_prefix .. "-at"
    local at_cookie = ngx.var[at_cookie_name]
    if not at_cookie then
        ngx.log(ngx.WARN, "No access token cookie was sent with the request")
        unauthorized_request_error_response(config)
    end

    -- Decrypt the access token cookie, which is encrypted using AES256
    local access_token = decrypt_cookie(at_cookie, config.encryption_key)
    if not access_token then
        ngx.log(ngx.WARN, "Error decrypting access token cookie")
        unauthorized_request_error_response(config)
    end

    -- Forward the access token to the next plugin or the target API
    ngx.req.set_header("Authorization", "Bearer " .. access_token)
end

return _M