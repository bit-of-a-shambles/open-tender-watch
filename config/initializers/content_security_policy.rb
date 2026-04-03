# Be sure to restart your server when you modify this file.

# Content Security Policy for Open Tender Watch.
# Hotwire (Turbo + Stimulus) uses importmap-driven ES modules, so scripts need
# a per-request nonce. Rails injects the nonce into script tags automatically
# when `content_security_policy_nonce_directives` includes "script-src".

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data, "https://fonts.gstatic.com"   # fonts.gstatic.com serves Google Font files
    policy.img_src     :self, :data, :https                         # data: for inline SVG/base64 used by Tailwind
    policy.object_src  :none                                        # no Flash / plugins
    policy.style_src   :self, :unsafe_inline, "https://fonts.googleapis.com"  # Tailwind inline + Google Fonts CSS
    policy.script_src  :self, :unsafe_inline                        # unsafe-inline needed for importmap/Hotwire inline scripts
    policy.connect_src :self                                        # no external XHR/WebSocket
    policy.frame_src   :none
    policy.base_uri    :self
    policy.form_action :self
  end

  # Nonce generator kept for any future nonce-gated scripts; directives left empty
  # so Rails does NOT add a nonce to script-src (nonce + unsafe-inline cancels each other out
  # in CSP2+ browsers, causing inline scripts to be blocked unexpectedly).
  config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[]
end
