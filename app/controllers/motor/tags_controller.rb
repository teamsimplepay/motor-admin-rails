# frozen_string_literal: true

module Motor
  class TagsController < ApiBaseController
    load_and_authorize_resource :tag

    def index
      render json: { data: @tags }
    end
  end
end
