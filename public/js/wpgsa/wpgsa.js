// wpgsa.js v0.1.0
// script for wpgsa.org
// copyright: Tazro Inutano Ohta inutano@gmail.com

// onload
$(function(){
  // enable filestyle
  $(":file").filestyle();

  // top page
  submitExpressionData();

  // result page
  drawHeatmap();
});

// functions
// top page

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

function submitExpressionData(){
  $('input#uploadUserDataFile').on('click', function(){
    var formData = new FormData($('form#uploadUserDataFile').get(0));
    UserData.upload(formData).done(function(json){
      var zScoreDataPath = $.grep(json, function(url){ return url.includes("z_score"); });
      var uuid = zScoreDataPath[0].split("/")[1];
      var redirectUrl = '/result?uuid=' + uuid
      window.open(redirectUrl, "_self", "");
    }).fail(function(json){
      console.log("Failed to upload data.");
    });
    return false;
  });
}

// result page

function drawHeatmap(){
  retrieveResult();
  hclust();
  heatmap();
}

function retrieveResult(){}
function hclust(){}
function heatmap(){}
