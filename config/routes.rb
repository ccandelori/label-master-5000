Rails.application.routes.draw do
  mount ActionCable.server => "/cable"

  root "label_applications#new"

  get "validation", to: "label_applications#new", as: :validation
  get "history", to: "reviewer/queue#index", as: :validation_history
  get "data-quality", to: "reviewer/data_quality#index", as: :data_quality

  get "rules", to: "rules#index"
  get "up/dependencies" => "runtime_dependencies#show", as: :runtime_dependencies_health_check

  resources :label_applications, only: %i[new create show edit update] do
    resource :decision, only: %i[create destroy]
    resource :submission, only: :create
    resource :rejection_notice, only: :show
    resource :check, only: :create
    resource :field_crop, only: :show
  end
  resource :sample_validation, only: :create

  resources :batches, only: %i[new create show] do
    scope module: :batches do
      resource :export, only: :show, defaults: { format: :csv }
      resource :retry, only: :create
    end
    resource :submission, only: :create, controller: "batch_submissions"
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
