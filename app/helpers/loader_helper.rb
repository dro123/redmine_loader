########################################################################
# File:    loader_helper.rb                                            #
#          Based on work by Hipposoft 2008                             #
#                                                                      #
# Purpose: Support functions for views related to Task Import objects. #
#          See controllers/loader_controller.rb for more.              #
#                                                                      #
# History: 04-Jan-2008 (ADH): Created.                                 #
#          Feb 2009 (SJS): Hacked into plugin for redmine              #
########################################################################

module LoaderHelper 

  def loaderhelp_user_selector( project )

    # First populate the selection box with all the existing categories from this project
    memberList = Member.find( :all, :conditions => { :project_id => project } )

    userList = []
    
    memberList.each do | current_member |
	  user = User.find( :first, :conditions => { :id => current_member.user_id } )
	  if user != nil
	    userList.push( user )
	  end
    end
    
    return [["", 0]] + userList.collect{|u| [u.firstname + " " + u.lastname, u.id]}
  end
  
end