// eslint-disable-next-line ember/no-classic-components
import Component from '@ember/component';
import { action } from '@ember/object';
import { inject } from '@ember/service';
import { tagName } from '@ember-decorators/component';
import bootbox from 'bootbox';
import classic from 'ember-classic-decorator';

@classic
@tagName("")
export default class UrlMatchTable extends Component {
  @inject()
  store;

  openModal = false;

  @action
  add() {
    this.set('urlMatchModel', this.store.createRecord('api/url-match'));
    this.set('openModal', true);
  }

  @action
  edit(urlMatch) {
    this.set('urlMatchModel', urlMatch);
    this.set('openModal', true);
  }

  @action
  remove(urlMatch) {
    bootbox.confirm('Are you sure you want to remove this URL prefix?', function(response) {
      if(response) {
        this.model.urlMatches.removeObject(urlMatch);
      }
    }.bind(this));
  }
}
