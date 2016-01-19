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
  $('input#sendUserDataFile').on('click', function(){
    var formData = new FormData($('input#userDataFile').get(0));
    UserData.upload(formData).done(function(json){
      var zScoreDataPath = json.filter(function(url){ url.includes("z_score") })[0];
      var uuid = zScoreDataPath.split("/")[1];
      window.open('/result?uuid='+uuid);
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
