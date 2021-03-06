import log from 'electron-log';
import * as React from 'react';
import styled from 'styled-components';
import { messages } from '../../shared/gettext';
import { Scheduler } from '../../shared/scheduler';

interface IProps {
  value: string;
  displayValue?: string;
  delay: number;
  message: string;
  className?: string;
}

interface IState {
  showsMessage: boolean;
}

const Label = styled.span({
  cursor: 'pointer',
});

export default class ClipboardLabel extends React.Component<IProps, IState> {
  public static defaultProps: Partial<IProps> = {
    delay: 3000,
    message: messages.gettext('COPIED TO CLIPBOARD!'),
  };

  public state: IState = {
    showsMessage: false,
  };

  private scheduler = new Scheduler();

  public componentWillUnmount() {
    this.scheduler.cancel();
  }

  public render() {
    const displayValue = this.props.displayValue || this.props.value;
    return (
      <Label className={this.props.className} onClick={this.handlePress}>
        {this.state.showsMessage ? this.props.message : displayValue}
      </Label>
    );
  }

  private handlePress = async () => {
    try {
      await navigator.clipboard.writeText(this.props.value);
      this.scheduler.schedule(() => this.setState({ showsMessage: false }), this.props.delay);
      this.setState({ showsMessage: true });
    } catch (error) {
      log.error(`Failed to copy to clipboard: ${error.message}`);
    }
  };
}
