// upload.js v0.1.0
// script for wpgsa.org
// copyright: Tazro Inutano Ohta inutano@gmail.com

// onload
$(function(){
  // enable filestyle
  $(":file").filestyle();

  // upload data
  uploadExpressionData();
});

// functions

var UserData = {
  upload: function(formData){
    var defer = $.Deferred();
    $.ajax({
      url: '/wpgsa/result',
      type: 'POST',
      data: formData,
      processData: false,
      contentType: false,
      dataType: 'json',
      success: defer.resolve,
      error: defer.reject
    });
    return defer.promise();
  }
};

function uploadExpressionData(){
  $('input#uploadUserDataFile').on('click', function(){
    // start upload sequence
    startLoading();
    var button = $(this);
    button.prop("disable", true);

    // get upload data
    var formData = new FormData($('form#uploadUserDataFile').get(0));
    UserData.upload(formData).done(function(json){
      var zScoreDataPath = $.grep(json, function(url){ return url.includes("z_score"); });
      var uuid = zScoreDataPath[0].split("/")[1];
      var redirectUrl = '/result?uuid=' + uuid
      // finish upload sequence
      removeLoading();
      button.prop("disable", false);
      // open result page
      window.open(redirectUrl, "_self", "");
    }).fail(function(json){
      // finish upload sequence
      removeLoading();
      button.prop("disable", false);
      alert("Error!");
    });
    return false;
  });
}

function startLoading(msg){
  var msg = "Data uploaded: started analysis, this may take a while..";
  var dispMsg = "<div class='loadingMsg'>" + msg + "</div>";
  if ($(".loading").size() == 0) {
    $.each($(".load-image"), function(){
      $(this).append("<div class='loading'>" + dispMsg + "</div>");
    });
  }
}

function removeLoading(){
  $.each($(".loading"), function(){
    $(this).remove();
  });
}
