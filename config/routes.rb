Rails.application.routes.draw do
  # Three areas share one unauthenticated app for demo purposes; a real
  # deployment would split the reviewer and manufacturer surfaces into
  # separately authenticated portals.
  root "reviewer/queue#index"

  namespace :reviewer do
    get "queue", to: "queue#index", as: :queue
  end

  get "rules", to: "rules#index"

  resources :label_applications, only: %i[new create show edit update] do
    resources :decisions, only: :create
    resource :submission, only: :create
  end

  resources :batches, only: %i[new create show] do
    member do
      get :export, defaults: { format: :csv }
      post :retry_failed
    end
    resource :submission, only: :create, controller: "batch_submissions"
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
