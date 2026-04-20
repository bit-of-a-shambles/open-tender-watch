Rails.application.routes.draw do
  root "dashboard#index"
  get "dashboard/index"
  resources :contracts, only: [ :index, :show ]
  resources :entities, only: [ :index, :show ]
  resources :companies, only: [ :index, :show ]
  match "locale/:locale", to: "locales#set", via: [ :get, :post ], as: :set_locale

  # Access token authentication for journalists
  get  "access", to: "tokens#new", as: :new_access_token
  post "access", to: "tokens#create", as: :access_token
  delete "access", to: "tokens#destroy", as: :destroy_access_token

  # Admin panel (protected by ADMIN_PASSWORD env var)
  get "admin", to: "admin#index", as: :admin
  get "admin/tokens", to: "admin#tokens", as: :admin_tokens
  get "admin/tokens/:id", to: "admin#token_detail", as: :admin_token_detail

  # Privacy policy
  get "privacy", to: "pages#privacy", as: :privacy

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
