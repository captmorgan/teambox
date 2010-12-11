require 'spec_helper'

describe Project do 
  describe 'roles' do 
    before do
      @owner = Factory.create(:user)
      @project = Factory.create(:project, :user_id => @owner.id)
    end

    it "should allow owner to edit this project" do
      @project.editable?(@owner).should == true
    end

    it "should not allow observer to edit this project" do
      user = Factory.create(:user)
      commentor = Factory.create(:person, :user_id => user.id, :project_id => @project.id, :role => Person::ROLES[:observer])
      @project.editable?(user).should == false
    end

    it "should not allow commenter to edit this project" do
      user = Factory.create(:user)
      commentor = Factory.create(:person, :user_id => user.id, :project_id => @project.id, :role => Person::ROLES[:commenter])
      @project.editable?(user).should == false
    end

    it "should allow participant to edit this project" do
      user = Factory.create(:user)
      participant = Factory.create(:person, :user_id => user.id, :project_id => @project.id, :role => Person::ROLES[:participant])
      @project.editable?(user).should == true
    end

    it "should allow admin to edit this project" do
      user = Factory.create(:user)
      participant = Factory.create(:person, :user_id => user.id, :project_id => @project.id, :role => Person::ROLES[:admin])
      @project.editable?(user).should == true
    end
  end
end