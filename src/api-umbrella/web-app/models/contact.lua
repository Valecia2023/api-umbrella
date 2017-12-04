local contact_mailer = require "api-umbrella.web-app.mailers.contact"
local contact_policy = require "api-umbrella.web-app.policies.contact_policy"
local is_empty = require("pl.types").is_empty
local t = require("api-umbrella.web-app.utils.gettext").gettext
local validate_field = require("api-umbrella.web-app.utils.model_ext").validate_field
local validation_ext = require "api-umbrella.web-app.utils.validation_ext"

local _M = {}


local function validate(values)
  local errors = {}
  validate_field(errors, values, "name", t("Name"), {
    { validation_ext.string:minlen(1), t("Provide your first name.") },
  })
  validate_field(errors, values, "email", t("Email"), {
    { validation_ext.string:minlen(1), t("Provide your email address.") },
    { validation_ext.optional:regex([[.+@.+\..+]], "jo"), t("Provide a valid email address.") },
  })
  validate_field(errors, values, "api", t("API"), {
    { validation_ext.string:minlen(1), t("Provide the API.") },
  })
  validate_field(errors, values, "subject", t("Subject"), {
    { validation_ext.string:minlen(1), t("Provide a subject.") },
  })
  validate_field(errors, values, "message", t("Message"), {
    { validation_ext.string:minlen(1), t("Provide a message.") },
  })
  return errors
end

function _M.authorized_deliver(_, values)
  contact_policy.authorize_create()

  local errors = validate(values)
  if not is_empty(errors) then
    return coroutine.yield("error", errors)
  end

  local ok, err = contact_mailer(values)
  if not ok then
    ngx.log(ngx.ERR, "mail error: ", err)
    return false
  else
    return true
  end
end

return _M
