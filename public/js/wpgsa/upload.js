// upload.js v0.1.0
// script for wpgsa.org
// copyright: Tazro Inutano Ohta inutano@gmail.com

// onload
$(function(){
  // polyfill
  pInclude();

  // enable filestyle
  $(":file").filestyle();

  // upload data
  uploadExpressionData();
});

// polyfill

function pInclude(){
  if (!String.prototype.includes) {
    String.prototype.includes = function(search, start) {
      'use strict';
      if (typeof start !== 'number') {
        start = 0;
      }

      if (start + search.length > this.length) {
        return false;
      } else {
        return this.indexOf(search, start) !== -1;
      }
    };
  }
}

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
      var tScoreDataPath = $.grep(json, function(url){ return url.includes("t_score"); });
      var uuid = tScoreDataPath[0].split("/")[1];
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
      alert("An error occurred during the process.\n\nCheck your file format and make sure to use recommended browsers (Latest Google Chrome or Safari). If you can not solve this problem yourself, contact us from 'report issues' on menu bar.");
    });
    return false;
  });
}

function startLoading(msg){
  var msg = "Data uploaded, started analysis. This may take a while.."
  var span = "<span class='msg'>" + msg + "</span>";
  var dispMsg = "<div class='loadingMsg'>" + span + "</div>";
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
