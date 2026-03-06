# Be sure to restart your server when you modify this file.

# Content Security Policy for Open Tender Watch.
# Hotwire (Turbo + Stimulus) uses importmap-driven ES modules, so scripts need
# a per-request nonce. Rails injects the nonce into script tags automatically
# when `content_security_policy_nonce_directives` includes "script-src".

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data, :https          # data: for inline SVG/base64 used by Tailwind
    policy.object_src  :none                          # no Flash / plugins
    policy.style_src   :self, :unsafe_inline          # Tailwind utility classes use inline styles
    policy.script_src  :self, :unsafe_inline  # nonce is injected automatically by Rails for importmap + Hotwire
    policy.connect_src :self                          # no external XHR/WebSocket (no external APIs in browser)
    policy.frame_src   :none
    policy.base_uri    :self
    policy.form_action :self
  end

  # Generate a unique nonce per request and inject it into all script tags.
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src]
end

