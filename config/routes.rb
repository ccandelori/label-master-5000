Rails.application.routes.draw do
  root "label_applications#new"

  resources :label_applications, only: %i[new create show edit update] do
    resources :decisions, only: :create
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
