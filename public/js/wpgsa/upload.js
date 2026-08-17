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

var UserJob = {
  status: function(uuid){
    var defer = $.Deferred();
    $.ajax({
      url: '/wpgsa/job?uuid=' + uuid,
      type: 'GET',
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
    button.prop("disabled", true);

    // get upload data
    var formData = new FormData($('form#uploadUserDataFile').get(0));
    UserData.upload(formData).done(function(json){
      pollJobStatus(json.uuid, button);
    }).fail(function(json){
      // finish upload sequence
      removeLoading();
      button.prop("disabled", false);
      alert("An error occurred during the process.\n\nCheck your file format and make sure to use recommended browsers (Latest Google Chrome or Safari). If you can not solve this problem yourself, contact us from 'report issues' on menu bar.");
    });
    return false;
  });
}

function pollJobStatus(uuid, button){
  UserJob.status(uuid).done(function(job){
    switch(job.status) {
    case "finished":
      removeLoading();
      button.prop("disabled", false);
      window.open('/result?uuid=' + uuid, "_self", "");
      break;
    case "failed":
      removeLoading();
      button.prop("disabled", false);
      var msg = "An error occurred during the process.";
      if (job.error_message) {
        msg += "\n\n" + job.error_message;
      }
      alert(msg);
      break;
    default:
      startLoading("Data uploaded, analysis in progress. This may take a while..");
      setTimeout(function(){
        pollJobStatus(uuid, button);
      }, 3000);
      break;
    }
  }).fail(function(){
    setTimeout(function(){
      pollJobStatus(uuid, button);
    }, 3000);
  });
}

function startLoading(msg){
  var msg = msg || "Data uploaded, started analysis. This may take a while.."
  if ($(".loading .msg").length > 0) {
    $(".loading .msg").text(msg);
    return;
  }
  var span = "<span class='msg'>" + msg + "</span>";
  var dispMsg = "<div class='loadingMsg'>" + span + "</div>";
  if ($(".loading").length == 0) {
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
