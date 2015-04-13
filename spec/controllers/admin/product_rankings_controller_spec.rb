require 'spec_helper'

describe Admin::ProductRankingsController do

  let(:current_user) { User.make!(is_staff: true) }

  before do
    sign_in(current_user)
  end

  describe "GET product ranking page" do
    it "is successful" do
      get :index
      expect(response).to be_success
    end
  end

end
