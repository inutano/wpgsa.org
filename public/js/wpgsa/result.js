// result.js v0.1.0
// script for wpgsa.org
// copyright: Tazro Inutano Ohta inutano@gmail.com

// onload
$(function(){
  // retrieve result and draw heatmap
  drawHeatmap();
});

// functions
// common

var getUrlParameter = function getUrlParameter(sParam) {
  var sPageURL = decodeURIComponent(window.location.search.substring(1)),
    sURLVariables = sPageURL.split('&'),
    sParameterName,
    i;

  for (i = 0; i < sURLVariables.length; i++) {
    sParameterName = sURLVariables[i].split('=');
    if (sParameterName[0] === sParam) {
      return sParameterName[1] === undefined ? true : sParameterName[1];
    }
  }
};

// draw heatmap

function drawHeatmap(){
  retrieveResult();
  hclust();
  heatmap();
}

var GetResult = {
  z_score: function(uuid){
    var defer = $.Deferred();
    $.ajax({
      url: "/wpgsa/result?uuid=" + uuid + "&type=z_score",
      type: 'GET',
      dataType: 'json',
      success: defer.resolve,
      error: defer.reject
    });
    return defer.promise();
  }
};

function retrieveResult(){
  var uuid = getUrlParameter('uuid');
  GetResult.z_score(uuid).done(function(json){
    string = JSON.stringify(json);
    $('#heatmap').append(string);
  });
}

function hclust(){}
function heatmap(){}
