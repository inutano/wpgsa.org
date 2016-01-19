// wpgsa.js v0.1.0
// script for wpgsa.org
// copyright: Tazro Inutano Ohta inutano@gmail.com

// onload
$(function(){
  // top page
  submitExpressionData();

  // result page
  drawHeatmap(){};
});

// functions
// top page

function submitExpressionData(){
  retrieveUserData();
  submitUserData();
}

function retrieveUserData(){}
function submitUserData(){}

// result page

function drawHeatmap(){
  retrieveResult();
  hclust();
  heatmap();
}

function retrieveResult(){}
function hclust(){}
function heatmap(){}
