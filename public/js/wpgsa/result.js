// result.js v0.1.0
// script for wpgsa.org
// copyright: Tazro Inutano Ohta inutano@gmail.com

// onload
$(function(){
  // set filename to page header
  setResultPageHeader();
  // set buttons to download result files
  setDownloadButtons();
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

// result page rendering

getResultData = function(uuid, type, format){
  var defer = $.Deferred();
  $.ajax({
    url: "/wpgsa/result?uuid=" + uuid + "&type=" + type + "&format=" + format,
    type: 'GET',
    success: defer.resolve,
    error: defer.reject
  });
  return defer.promise();
}

function setResultPageHeader(){
  var uuid = getUrlParameter('uuid');
  getResultData(uuid, "input", "filepath").done(function(fpath){
    var filename = $('<div class="small">' + fpath.replace(/^.+\//,"") + '</div>');
    $('h2').append(filename);
  });
}

function setDownloadLink(element, type){
  var uuid = getUrlParameter('uuid');
  getResultData(uuid, type, "filepath").done(function(fpath){
    var filename = fpath.replace(/^.+\//,"");
    element.attr("href", fpath).attr("download", filename);
  });
}

function setDownloadButtons(){
  setDownloadLink($('a#pValue'), "p-value");
  setDownloadLink($('a#qValue'), "q-value");
  setDownloadLink($('a#tScore'), "t-score");
}
